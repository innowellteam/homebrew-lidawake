class Lidawake < Formula
  desc "Menu bar toggle that keeps your Mac awake with the lid closed"
  homepage "https://github.com/sheldon-innowell/lidawake"
  # The repo is private, so fetch with git (and your GitHub login) rather than a release tarball.
  url "https://github.com/sheldon-innowell/lidawake.git", tag: "v1.0.0"
  license "MIT"
  head "https://github.com/sheldon-innowell/lidawake.git", branch: "main"

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

      Before uninstalling, turn lid sleep back on and remove the rule:
        sudo pmset -a disablesleep 0
        sudo rm /etc/sudoers.d/lidawake
    EOS
  end

  test do
    assert_predicate prefix/"LidAwake.app/Contents/MacOS/LidAwake", :executable?
  end
end
