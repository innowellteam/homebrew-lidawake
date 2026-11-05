class Lidawake < Formula
  desc "Menu bar toggle that keeps your Mac awake with the lid closed"
  homepage "https://github.com/innowellteam/homebrew-lidawake"
  # The repo is internal, and Homebrew downloads source in a sandbox that can't use your GitHub
  # login. This repo is also the tap, so brew already has a clone of it: build from that.
  url "file://#{Tap.fetch("innowellteam", "lidawake").path}", using: :git, tag: "v1.2.0", revision: "25f674a078d7d8ef5bdc247bbd4a4d4a5f5e8986"
  license "MIT"
  head "file://#{Tap.fetch("innowellteam", "lidawake").path}", using: :git, branch: "main"

  # Prebuilt by `make bottle` and kept in the tap too, so installing needs no compiler and no
  # Xcode Command Line Tools. The app is universal and needs macOS 13, so one bottle fits all.
  bottle do
    root_url "file://#{Tap.fetch("innowellteam", "lidawake").path}/bottles"
    sha256 cellar: :any_skip_relocation, all: "b2a277c9f1a12db6e3f4ba313073c40c8a468468f382996142ae9d58d9eb7e31"
  end

  depends_on :macos

  def install
    system "make", "install", "PREFIX=#{prefix}"
  end

  service do
    run opt_prefix/"LidAwake.app/Contents/MacOS/LidAwake"
    process_type :interactive
  end

  def caveats
    <<~EOS
      Left-click the menu bar icon to toggle, right-click for the menu.
      The first toggle asks for your password once, to install
      /etc/sudoers.d/lidawake (it only allows pmset disablesleep 0/1).

      For heat alerts on your phone, install the ntfy app and choose
      "Phone Alerts..." from the menu.

      Before uninstalling, turn lid sleep back on and remove the rule:
        sudo pmset -a disablesleep 0
        sudo rm /etc/sudoers.d/lidawake
    EOS
  end

  test do
    assert_predicate prefix/"LidAwake.app/Contents/MacOS/LidAwake", :executable?
  end
end
