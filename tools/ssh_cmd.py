import sys
import paramiko

HOST, USER, PASS = "10.168.1.114", "tyzc", "123456"

def main():
    cmd = sys.argv[1]
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, username=USER, password=PASS, timeout=10)
    stdin, stdout, stderr = cli.exec_command(cmd, timeout=120)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    sys.stdout.write(out)
    if err:
        sys.stdout.write("\n[STDERR]\n" + err)
    cli.close()

if __name__ == "__main__":
    main()
