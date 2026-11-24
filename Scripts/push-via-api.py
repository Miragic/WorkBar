#!/usr/bin/env python3
"""把当前 git 仓库的工作树通过 GitHub REST API 上传到指定仓库。

## 为什么不用 `git push`
这台机器到 `github.com`（git 传输层走的就是它）不通：
系统代理 127.0.0.1:1082 放行 `api.github.com`（200），但 `github.com` 一律超时。
所以绕开 git 协议，改用 Git Data API：建 blob → 建 tree → 建 commit → 建 ref。

## 代价（必须知道）
只产出**一个**提交，本地提交粒度会丢失；commit message 里写明这件事。

## 用法
    python3 Scripts/push-via-api.py --repo Miragic/WorkBar --token-file ~/.workbuddy/gh_token
    python3 Scripts/push-via-api.py --repo Miragic/WorkBar --token-file ~/.workbuddy/gh_token --dry-run

## token 权限
- fine-grained：`Contents: Read and write`（仓库已存在，不需要 Administration）
- classic：勾 `repo`

## 安全
token 只用于本次请求的 Authorization 头，不写入 git config / remote URL / 任何文件。
"""
import argparse
import atexit
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

API = "https://api.github.com"


def die(msg):
    print("[push] 失败：" + msg, file=sys.stderr)
    sys.exit(1)


def system_proxy():
    """从 macOS 系统代理设置里取 HTTP 代理（git/curl 不会自动读它，浏览器会）。

    不解这个就走不通：本机 curl 只认环境变量，而环境里那个 127.0.0.1:52179
    是 WorkBuddy 自己的代理，不放行 github.com/api.github.com。
    """
    try:
        out = subprocess.check_output(["scutil", "--proxy"], text=True)
    except Exception:
        return None
    info = {}
    for line in out.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            info[k.strip()] = v.strip()
    if info.get("HTTPEnable") != "1":
        return None
    host, port = info.get("HTTPProxy"), info.get("HTTPPort")
    if not host or not port:
        return None
    return "http://%s:%s" % (host, port)


class Client:
    """用 `curl` 作为传输层，而不是 urllib。

    原因（实测）：本机系统代理是 Clash 一类只做 HTTP CONNECT 转发的代理，
    Python 的 `urllib` 走它会卡在 TLS 握手（`_ssl.c:1015 handshake timed out`），
    而同一个代理下 curl 请求 `api.github.com` 是 200。既然 curl 能用，就用它。

    token 通过 `curl -K 配置文件` 传入，**不出现在命令行参数里**（否则 `ps` 能看到）。
    """

    def __init__(self, token, proxy):
        self.dir = tempfile.mkdtemp(prefix="ghpush.")
        cfg = self.dir + "/curl.cfg"
        lines = [
            'header = "Authorization: Bearer %s"' % token,
            'header = "Accept: application/vnd.github+json"',
            'header = "X-GitHub-Api-Version: 2022-11-28"',
            'header = "Content-Type: application/json"',
            'user-agent = "workbar-push"',
            "silent", "show-error", "max-time = 120",
        ]
        if proxy:
            lines.append('proxy = "%s"' % proxy)
        with open(cfg, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        os.chmod(cfg, 0o600)
        self.cfg = cfg
        # 无论正常结束还是中途 die()，都要删掉含 token 的临时目录。
        atexit.register(self.cleanup)

    def call(self, method, path, payload=None, expect=(200, 201, 204), retries=3):
        data = json.dumps(payload) if payload is not None else None
        for attempt in range(1, retries + 1):
            # 每次调用独立的输出文件：上传是 6 路并发的，共用同一个文件会互相覆盖
            # （一开始就踩了：多个 blob 请求抢同一份 body.json，服务端收到错乱内容）。
            fd, out_file = tempfile.mkstemp(dir=self.dir)
            os.close(fd)
            # 请求体走 stdin（`--data-binary @-`），连临时 body 文件都不需要，天然无竞态。
            cmd = ["curl", "-K", self.cfg, "-o", out_file, "-w", "%{http_code}",
                   "-X", method]
            if data is not None:
                cmd += ["--data-binary", "@-"]
            cmd.append(API + path)
            proc = subprocess.run(cmd, capture_output=True, text=True, input=data or "")
            code = (proc.stdout or "").strip()
            if code.isdigit():
                raw = open(out_file).read() if os.path.exists(out_file) else ""
                os.unlink(out_file)
                try:
                    body = json.loads(raw) if raw else None
                except json.JSONDecodeError:
                    body = {"raw": raw}
                return int(code), body
            os.unlink(out_file)
            # 连不上（curl 非零退出 / 拿不到状态码）：这条网络会间歇性抽风，退避重试。
            if attempt == retries:
                die("网络不可达（curl: %s）。检查系统代理是否在跑。"
                    % (proc.stderr.strip() or "no status"))
            time.sleep(1.5 * attempt)

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)


def read_token(args):
    if args.token_file:
        path = os.path.expanduser(args.token_file)
        if not os.path.exists(path):
            die("token 文件不存在：%s" % path)
        token = open(path).read().strip()
    else:
        token = (os.environ.get("GH_PUSH_TOKEN") or "").strip()
    if not token:
        die("没有拿到 token。用 --token-file 或 GH_PUSH_TOKEN 提供。")
    return token


def tracked_files():
    """git 跟踪的文件（自动尊重 .gitignore，排除 build/ .verify/ 等本地产物）。"""
    out = subprocess.check_output(["git", "ls-files", "-z"])
    return [p for p in out.decode().split("\0") if p]


def is_executable(path):
    return os.access(path, os.X_OK)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="owner/name，例如 Miragic/WorkBar")
    ap.add_argument("--token-file")
    ap.add_argument("--proxy", help="覆盖系统代理，例如 http://127.0.0.1:1082")
    ap.add_argument("--description", default="在 Touch Bar 上常驻显示 WorkBuddy 任务状态的 macOS 小工具")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--update", action="store_true",
                    help="仓库已有内容时，在现有提交之上追加一个提交（不丢远端历史）")
    args = ap.parse_args()

    if "/" not in args.repo:
        die("--repo 需要 owner/name 形式，例如 Miragic/WorkBar")
    owner, name = args.repo.split("/", 1)

    files = tracked_files()
    if not files:
        die("git 里没有跟踪的文件，检查是否在仓库根目录执行。")
    total = sum(os.path.getsize(f) for f in files)
    print("[push] 待上传 %d 个文件，合计 %.1f KB" % (len(files), total / 1024))

    if args.dry_run:
        for f in files:
            print("   %s%s" % (f, "  (可执行)" if is_executable(f) else ""))
        print("[push] --dry-run：未发送任何请求")
        return

    proxy = args.proxy
    if proxy is None:
        proxy = system_proxy()
    elif proxy.lower() in ("none", "direct", ""):
        # 显式要求直连：实测这台机器直连 api.github.com 是 200，
        # 而系统代理（127.0.0.1:1082）时开时关，关着的时候反而是它拖累。
        proxy = None
    print("[push] 代理：%s" % (proxy or "直连"))
    client = Client(read_token(args), proxy)

    status, me = client.call("GET", "/user")
    if status != 200:
        die("token 无效或权限不足（GET /user -> %s）：%s" % (status, me.get("raw", "")))
    print("[push] 已认证：%s" % me["login"])

    # 仓库已存在则直接复用（用户可能已在网页上建好）。
    # 是否「可安全覆盖」不看 `size`：它是异步统计的，而且引导提交本身就会让它变成非 0，
    # 重试时会误判。改成看 main 上到底有什么内容（见下）。
    status, repo = client.call("GET", "/repos/%s/%s" % (owner, name))
    if status == 200:
        print("[push] 复用已存在仓库：%s" % repo["html_url"])
    elif status == 404:
        status, repo = client.call("POST", "/user/repos", {
            "name": name, "description": args.description, "private": False,
            "has_issues": True, "has_wiki": False, "auto_init": False,
        })
        if status not in (200, 201):
            die("建仓失败（%s）：%s" % (status, repo.get("raw", "")))
        print("[push] 仓库已创建：%s" % repo["html_url"])
    else:
        die("读取仓库失败（%s）：%s" % (status, repo.get("raw", "")))

    # 空仓库有个坑：GitHub 不允许在**完全没有提交**的库里创建 blob，
    # 一律返回 `409 Git Repository is empty.`（curl 手动复现过）。
    # 所以先用 Contents API 写一个占位文件把初始提交建出来；该提交随后会被我们
    # 自己的孤儿提交顶掉（ref 强制指向新提交），占位文件不会出现在最终树里。
    st_ref, ref_info = client.call("GET", "/repos/%s/%s/git/ref/heads/main" % (owner, name))
    parent_sha = None
    if st_ref == 200:
        sha = ref_info["object"]["sha"]
        _, ci = client.call("GET", "/repos/%s/%s/git/commits/%s" % (owner, name, sha))
        paths = []
        if ci and ci.get("tree"):
            _, ti = client.call("GET", "/repos/%s/%s/git/trees/%s"
                                % (owner, name, ci["tree"]["sha"]))
            if ti:
                paths = [e["path"] for e in ti.get("tree", [])]
        unexpected = set(paths) - {".workbar-bootstrap"}
        if unexpected and not args.update:
            die("仓库里已有 %d 项内容。确实要覆盖就用 --update（会在现有提交之上追加一个提交，"
                "不会丢历史）。" % len(unexpected))
        parent_sha = sha
        print("[push] 在现有提交 %s 之上追加提交" % sha[:7])
    else:
        print("[push] 空仓库：先引导出首个提交（否则建 blob 会被 409 拒绝）")
        st, body = client.call(
            "PUT", "/repos/%s/%s/contents/.workbar-bootstrap" % (owner, name),
            {"message": "Initialize repository", "content": base64.b64encode(b"WorkBar\n").decode()})
        if st not in (200, 201):
            die("引导初始提交失败（%s）：%s" % (st, body.get("raw", "")))
        # 刚建完提交时后端 git 库有短暂传播延迟；此时并发发 blob 仍会撞到
        # `409 Git Repository is empty.`（实测零星一两个失败）。等 main 真正可读再继续。
        for _ in range(20):
            st_wait, _ = client.call("GET", "/repos/%s/%s/git/ref/heads/main" % (owner, name))
            if st_wait == 200:
                break
            time.sleep(1)
        else:
            die("初始提交创建后 main 分支仍不可读，放弃。")

    def make_blob(path):
        with open(path, "rb") as fh:
            content = base64.b64encode(fh.read()).decode()
        st, body = client.call("POST", "/repos/%s/%s/git/blobs" % (owner, name),
                              {"content": content, "encoding": "base64"})
        if st != 201:
            die("上传 %s 失败（%s）：%s" % (path, st, body.get("raw", "")))
        return path, body["sha"]

    with ThreadPoolExecutor(max_workers=6) as pool:
        blobs = dict(pool.map(make_blob, files))
    print("[push] blob 就绪 %d 个" % len(blobs))

    entries = [{"path": f,
                "mode": "100755" if is_executable(f) else "100644",
                "type": "blob",
                "sha": blobs[f]} for f in files]
    st, tree = client.call("POST", "/repos/%s/%s/git/trees" % (owner, name), {"tree": entries})
    if st != 201:
        die("建 tree 失败（%s）：%s" % (st, tree.get("raw", "")))

    count = subprocess.check_output(["git", "rev-list", "--count", "HEAD"]).decode().strip()
    last = subprocess.check_output(["git", "log", "-1", "--pretty=%s"]).decode().strip()
    if parent_sha:
        message = "Update: %s\n\n同步本地工作树（本地共 %s 个提交）。\n" % (last, count)
    else:
        message = (
            "Initial commit: WorkBar\n\n"
            "在 Touch Bar 上常驻显示 WorkBuddy 的任务状态（Swift / AppKit，零第三方依赖）。\n\n"
            "注：本提交由 GitHub REST API 上传，本地 %s 个提交的历史被压缩为单个初始提交\n"
            "（本机到 github.com 的 git 传输不通，只能走 api.github.com）。\n"
            "最后一个本地提交：%s\n"
        ) % (count, last)
    st, commit = client.call("POST", "/repos/%s/%s/git/commits" % (owner, name),
                             {"message": message, "tree": tree["sha"],
                              "parents": [parent_sha] if parent_sha else []})
    if st != 201:
        die("建 commit 失败（%s）：%s" % (st, commit.get("raw", "")))

    # 引导提交已经把 main 建出来了，所以这里不能再 POST /git/refs（会 422 已存在），
    # 直接强制把 main 指到我们这个孤儿提交上 —— 最终仓库里只有一个提交，
    # 引导用的占位文件随之消失（它不在我们的 tree 里）。
    st, ref = client.call("PATCH", "/repos/%s/%s/git/refs/heads/main" % (owner, name),
                          {"sha": commit["sha"], "force": parent_sha is None})
    if st not in (200, 201):
        # 极端情况：main 还不存在（引导那步被跳过），退回普通建 ref。
        st, ref = client.call("POST", "/repos/%s/%s/git/refs" % (owner, name),
                              {"ref": "refs/heads/main", "sha": commit["sha"]})
        if st != 201:
            die("建分支失败（%s）：%s" % (st, ref.get("raw", "")))

    print("[push] 完成：%s" % repo["html_url"])
    print("[push] 本地接上远端（后续如需在能连 github.com 的环境里 push）：")
    print("       git remote add origin %s.git" % repo["html_url"])


if __name__ == "__main__":
    main()
