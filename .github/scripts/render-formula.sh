#!/usr/bin/env bash
# Render the Homebrew formula for mobhook.
#
# Usage: render-formula.sh VERSION ARM_MAC X64_MAC ARM_LINUX X64_LINUX [OUTPUT]
#   VERSION   strict SemVer WITHOUT the leading "v" (e.g. 1.2.3, 1.2.3-rc.1)
#   *_MAC / *_LINUX   sha256 of the matching tarball, 64 lowercase/uppercase hex
#   OUTPUT    file to write (default: stdout)
#
# Every input is validated before use. The template is a QUOTED heredoc, so the
# shell never expands anything in it; values are substituted explicitly.
set -euo pipefail

SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$'
SHA_RE='^[0-9A-Fa-f]{64}$'

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

if [ "$#" -lt 5 ] || [ "$#" -gt 6 ]; then
  fail "usage: render-formula.sh VERSION ARM_MAC X64_MAC ARM_LINUX X64_LINUX [OUTPUT]"
fi

version="$1"
arm_mac="$2"
x64_mac="$3"
arm_linux="$4"
x64_linux="$5"
output="${6:-}"

[[ "$version" =~ $SEMVER_RE ]] || fail "VERSION is not strict SemVer (no leading v)"
[[ "$arm_mac" =~ $SHA_RE ]] || fail "ARM_MAC is not a 64-char hex sha256"
[[ "$x64_mac" =~ $SHA_RE ]] || fail "X64_MAC is not a 64-char hex sha256"
[[ "$arm_linux" =~ $SHA_RE ]] || fail "ARM_LINUX is not a 64-char hex sha256"
[[ "$x64_linux" =~ $SHA_RE ]] || fail "X64_LINUX is not a 64-char hex sha256"

# `read -d ''` returns non-zero at EOF; that is expected.
read -r -d '' template <<'TEMPLATE' || true
class Mobhook < Formula
  desc "Mobile-first git hooks manager"
  homepage "https://github.com/iqbal-mekari/mobhook"
  version "@VERSION@"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/iqbal-mekari/mobhook/releases/download/v@VERSION@/mobhook-aarch64-apple-darwin.tar.gz"
      sha256 "@ARM_MAC@"
    else
      url "https://github.com/iqbal-mekari/mobhook/releases/download/v@VERSION@/mobhook-x86_64-apple-darwin.tar.gz"
      sha256 "@X64_MAC@"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/iqbal-mekari/mobhook/releases/download/v@VERSION@/mobhook-aarch64-unknown-linux-musl.tar.gz"
      sha256 "@ARM_LINUX@"
    else
      url "https://github.com/iqbal-mekari/mobhook/releases/download/v@VERSION@/mobhook-x86_64-unknown-linux-musl.tar.gz"
      sha256 "@X64_LINUX@"
    end
  end

  def install
    bin.install "mobhook"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/mobhook --version")
  end
end
TEMPLATE

rendered="${template//@VERSION@/$version}"
rendered="${rendered//@ARM_MAC@/$arm_mac}"
rendered="${rendered//@X64_MAC@/$x64_mac}"
rendered="${rendered//@ARM_LINUX@/$arm_linux}"
rendered="${rendered//@X64_LINUX@/$x64_linux}"

# Defence in depth: no placeholder may survive substitution.
case "$rendered" in
  *@VERSION@* | *@ARM_MAC@* | *@X64_MAC@* | *@ARM_LINUX@* | *@X64_LINUX@*)
    fail "unsubstituted placeholder left in formula"
    ;;
esac

if [ -n "$output" ]; then
  printf '%s\n' "$rendered" > "$output"
else
  printf '%s\n' "$rendered"
fi
