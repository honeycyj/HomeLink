import Foundation

nonisolated enum AuthorizationCommand {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func make(publicKey: String) -> String {
        // Match the algorithm and key blob even when a comment or authorized_keys options differ.
        let parts = publicKey.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, parts[0] == "ssh-ed25519",
              parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }) else { return "" }
        return """
        /bin/sh <<'HOMELINK_AUTHORIZE'
        set -eu
        umask 077
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        touch "$HOME/.ssh/authorized_keys"
        chmod 600 "$HOME/.ssh/authorized_keys"
        if ! /usr/bin/awk -v kind=\(quote(String(parts[0]))) -v blob=\(quote(String(parts[1]))) '
          /^[[:space:]]*#/ { next }
          {
            n=0; word=""; quoted=0; escaped=0
            for (i=1; i<=length($0); i++) {
              c=substr($0,i,1)
              if (escaped) { word=word c; escaped=0; continue }
              if (c == "\\\\") { word=word c; escaped=1; continue }
              if (c == "\\\"") { quoted=!quoted; word=word c; continue }
              if (c ~ /[[:space:]]/ && !quoted) {
                if (length(word)) { field[++n]=word; word="" }
              } else word=word c
            }
            if (length(word)) field[++n]=word
            if ((n>=2 && field[1]==kind && field[2]==blob) ||
                (n>=3 && field[2]==kind && field[3]==blob)) found=1
            delete field
          }
          END { exit !found }
        ' "$HOME/.ssh/authorized_keys"; then
          printf '\\n%s\\n' \(quote(publicKey)) >> "$HOME/.ssh/authorized_keys"
        fi
        printf '%s\\n' 'HomeLink 公钥已授权（已有公钥不会重复添加）。'
        HOMELINK_AUTHORIZE

        # SSH 安全说明（以下均为注释，不会修改现有配置）
        # 确认 HomeLink 密钥可以登录后，建议在 Studio 已有的独立 SSH 配置中设置：
        # PubkeyAuthentication yes
        # PasswordAuthentication no
        # KbdInteractiveAuthentication no
        # PermitRootLogin no
        # 已配置过则无需重复添加；不要覆盖原始配置或其他公钥。
        # 如需修改，请先备份并检查 Include 顺序和 Match 规则。
        # 语法检查：sudo /usr/sbin/sshd -t
        # 生效值检查：sudo /usr/sbin/sshd -T（有 Match 时还需使用 -C 检查相应上下文）
        # 保留旧连接，用新会话确认密钥与端口转发正常后再退出。
        """
    }
}
