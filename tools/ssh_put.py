import sys
import paramiko

HOST, USER, PASS = "10.168.1.114", "tyzc", "123456"

def main():
    local_path, remote_path = sys.argv[1], sys.argv[2]
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, username=USER, password=PASS, timeout=10)
    data = open(local_path, "rb").read().replace(b"\r\n", b"\n")
    stdin, stdout, stderr = cli.exec_command(f"cat > {remote_path}", timeout=30)
    stdin.write(data)
    stdin.channel.shutdown_write()
    stdout.read()
    if len(sys.argv) > 3 and sys.argv[3] in ("run", "py"):
        interp = "python3" if sys.argv[3] == "py" else "bash"
        stdin, stdout, stderr = cli.exec_command(f"{interp} {remote_path}", timeout=120)
        sys.stdout.write(stdout.read().decode("utf-8", "replace"))
        err = stderr.read().decode("utf-8", "replace")
        if err:
            sys.stdout.write("\n[STDERR]\n" + err)
    cli.close()

if __name__ == "__main__":
    main()
