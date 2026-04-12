#if os(macOS)
import Testing
@testable import Ghostty

struct TransportTests {
    @Test func shqRoundTrip() {
        #expect(shq("a") == "'a'")
        #expect(shq("a b") == "'a b'")
        #expect(shq("a';id;'b") == #"'a'\'';id;'\''b'"#)
        #expect(shq(["zmx", "attach", "x"]) == "'zmx' 'attach' 'x'")
    }

    @Test func wrapLocal() {
        let cmd = ForkHost.Transport.local.wrap(["zmx", "attach", "h-n"])
        #expect(cmd == "'zmx' 'attach' 'h-n'")
    }

    @Test func wrapSshGolden() {
        let t = ForkHost.SSHTarget(user: "deploy", host: "prod-web-01")
        let cmd = ForkHost.Transport.ssh(t).wrap(["zmx", "attach", "h-n"])
        #expect(cmd == #"'ssh' '-t' '--' 'deploy@prod-web-01' ''\''zmx'\'' '\''attach'\'' '\''h-n'\'''"#)
    }

    @Test func wrapSshInjection() {
        let t = ForkHost.SSHTarget(user: nil, host: "h")
        let cmd = ForkHost.Transport.ssh(t).wrap(["zmx", "attach", "a';id;'b"])
        #expect(!cmd.contains(";id;") || cmd.contains(#"'\'';id;'\''"#))
    }

    @Test func controlArgvSsh() {
        let t = ForkHost.SSHTarget(user: nil, host: "h")
        let argv = ForkHost.Transport.ssh(t).controlArgv(["zmx", "list", "--short"])
        #expect(argv == ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", "h", "'zmx' 'list' '--short'"])
    }

    @Test func sshTargetValidation() {
        #expect(ForkHost.SSHTarget(user: "deploy", host: "prod-web-01").isValid)
        #expect(ForkHost.SSHTarget(user: nil, host: "10.40.12.22").isValid)
        #expect(!ForkHost.SSHTarget(user: nil, host: "h;rm -rf").isValid)
        #expect(!ForkHost.SSHTarget(user: "u$(id)", host: "h").isValid)
    }

    @Test func sessionRefValidation() {
        #expect(SessionRef(hostID: "local", name: "shell-abc").isValid)
        #expect(!SessionRef(hostID: "local", name: "a;b").isValid)
    }

    @Test func wireName() {
        let ref = SessionRef(hostID: "abcd1234", name: "shell-x")
        #expect(ZmxAdapter.wireName(ref) == "abcd1234-shell-x")
    }
}
#endif
