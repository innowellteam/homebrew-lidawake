# LidAwake was renamed WellAwake in 2.0. This is LidAwake's last version: a stand-in (Bridge/) that an
# older LidAwake updates to by itself. It installs WellAwake and starts it at login, and WellAwake then
# uninstalls it. Keep it while any LidAwake installs might still be around.
class Lidawake < Formula
  desc "LidAwake's last version, which moves an install over to WellAwake"
  homepage "https://github.com/innowellteam/homebrew-wellawake"
  url "file://#{File.expand_path("..", __dir__)}", using: :git, tag: "v2.0.1", revision: "9c30300157772e87668acb50061ab5089f738ec2"
  license "MIT"

  bottle do
    root_url "file://#{File.expand_path("../bottles", __dir__)}"
    sha256 cellar: :any_skip_relocation, all: "dec9218d67661fc985813d6d41b83a4e11e295c79cfb640d967faa514864bda3"
  end

  depends_on :macos

  def install
    prefix.install "Bridge/LidAwake.app"
  end

  # Unchanged from LidAwake, so the restart an older LidAwake does after updating runs the stand-in.
  service do
    run opt_prefix/"LidAwake.app/Contents/MacOS/LidAwake"
    process_type :interactive
  end

  def caveats
    <<~EOS
      LidAwake is now WellAwake. Running as a brew service, it installs WellAwake and
      starts it by itself. Otherwise:
        brew install innowellteam/wellawake/wellawake
        brew services start wellawake
    EOS
  end

  test do
    assert_predicate prefix/"LidAwake.app/Contents/MacOS/LidAwake", :executable?
  end
end
