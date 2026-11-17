class Wellawake < Formula
  desc "Menu bar toggle that keeps your Mac awake with the lid closed"
  homepage "https://github.com/innowellteam/homebrew-wellawake"
  # The repo is internal, and Homebrew downloads source in a sandbox that can't use your GitHub
  # login. This repo is also the tap, so brew already has a clone of it: build from that.
  url "file://#{Tap.fetch("innowellteam", "wellawake").path}", using: :git, tag: "v1.8.0", revision: "bcf117ec04998ad6edc64081cfbb34bd19aefd0c"
  license "MIT"
  head "file://#{Tap.fetch("innowellteam", "wellawake").path}", using: :git, branch: "main"

  # Prebuilt by `make bottle` and kept in the tap too, so installing needs no compiler and no
  # Xcode Command Line Tools. The app is universal and needs macOS 13, so one bottle fits all.
  bottle do
    root_url "file://#{Tap.fetch("innowellteam", "wellawake").path}/bottles"
    sha256 cellar: :any_skip_relocation, all: "2deafd4b085c342a58d941b4872c05e831e6eb8b75551b4da0a5a90046c6882c"
  end

  depends_on :macos

  def install
    system "make", "install", "PREFIX=#{prefix}"
  end

  service do
    run opt_prefix/"WellAwake.app/Contents/MacOS/WellAwake"
    process_type :interactive
  end

  def caveats
    <<~EOS
      Left-click the menu bar icon to toggle, right-click for the menu.
      The first toggle asks for your password once, to install
      /etc/sudoers.d/wellawake (it only allows pmset disablesleep 0/1).

      For heat and battery alerts on your phone, install the ntfy app
      and choose "Phone Alerts..." from the menu.

      Before uninstalling, turn lid sleep back on and remove the rule:
        sudo pmset -a disablesleep 0
        sudo rm /etc/sudoers.d/wellawake
    EOS
  end

  test do
    assert_predicate prefix/"WellAwake.app/Contents/MacOS/WellAwake", :executable?
  end
end
