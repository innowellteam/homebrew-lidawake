class Wellawake < Formula
  desc "Menu bar toggle that keeps your Mac awake with the lid closed"
  homepage "https://github.com/innowellteam/homebrew-lidawake"
  # This repo is also the tap, so brew already has a clone of it: build from that. It's found from
  # this file's folder rather than by name, so it still works if the repo (and with it the tap) is renamed.
  url "file://#{File.expand_path("..", __dir__)}", using: :git, tag: "v2.1.0", revision: "ea3c2544ff7d2a1059df757e07d495f17ad10a68"
  license "MIT"
  head "file://#{File.expand_path("..", __dir__)}", using: :git, branch: "main"

  # Prebuilt by `make bottle` and kept in the tap too, so installing needs no compiler and no
  # Xcode Command Line Tools. The app is universal and needs macOS 13, so one bottle fits all.
  bottle do
    root_url "file://#{File.expand_path("../bottles", __dir__)}"
    sha256 cellar: :any_skip_relocation, all: "e49d4255cec1232f99afbad1535f61ae568d15d3e6568f64b325272f5882f2bf"
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
