import os
import sys
import paramiko

HOST = os.environ.get("RK_HOST", "10.168.1.115")
USER, PASS = "tyzc", "123456"

def main():
    local_path, remote_path = sys.argv[1], sys.argv[2]
    mode = sys.argv[3] if len(sys.argv) > 3 else ""
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, username=USER, password=PASS, timeout=10)
    data = open(local_path, "rb").read()
    # 只对文本做 CRLF->LF 归一化。二进制（ELF 等）里也可能出现 0x0d 0x0a，
    # 替换会损坏文件，所以用 NUL 字节作为二进制判据；mode=raw 可强制跳过。
    if mode != "raw" and b"\x00" not in data:
        data = data.replace(b"\r\n", b"\n")
    stdin, stdout, stderr = cli.exec_command(f"cat > {remote_path}", timeout=60)
    stdin.write(data)
    stdin.channel.shutdown_write()
    stdout.read()

    def run(cmd):
        _, out, err = cli.exec_command(cmd, timeout=120)
        sys.stdout.write(out.read().decode("utf-8", "replace"))
        e = err.read().decode("utf-8", "replace")
        if e:
            sys.stdout.write("\n[STDERR]\n" + e)

    if mode == "run":
        run(f"bash {remote_path}")
    elif mode == "py":
        run(f"python3 {remote_path}")
    elif mode == "exe":
        run(f"chmod +x {remote_path} && {remote_path}")
    cli.close()

if __name__ == "__main__":
    main()
