cask "codex-cove" do
  version "0.3.0"
  sha256 "2759d28cb8095d5b9528534c38de02230c45af9135bb8fd7ed1737cce09f4054"

  url "https://github.com/cdimartino/codex-cove/releases/download/v#{version}/Codex-Cove-#{version}-macos-arm64.zip",
      verified: "github.com/cdimartino/codex-cove/"
  name "Codex Cove"
  desc "Local task companion for Codex"
  homepage "https://github.com/cdimartino/codex-cove"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Codex Cove.app", target: "~/Applications/Codex Cove.app"

  postflight do
    app_path = File.expand_path("~/Applications/Codex Cove.app")

    system_command "#{app_path}/Contents/Resources/bin/codex-cove",
                   args: ["install", "--app-path", app_path],
                   env:  { "PATH" => ENV.fetch("HOMEBREW_PATH", ENV.fetch("PATH")) }
  end

  uninstall_preflight do
    ENV["PATH"] = ENV.fetch("HOMEBREW_PATH", ENV.fetch("PATH"))
  end

  uninstall quit:   "local.chris.codexcove",
            script: {
              executable: "~/Applications/Codex Cove.app/Contents/Resources/bin/codex-cove",
              args:       ["uninstall", "--keep-settings", "--keep-app"],
            }

  zap trash: [
    "~/Library/Application Support/Codex Cove",
    "~/Library/Preferences/local.chris.codexcove.plist",
    "~/Library/Saved Application State/local.chris.codexcove.savedState",
  ]

  caveats <<~EOS
    Codex Cove is installed in ~/Applications so its user-local integration
    and Accessibility permission remain bound to one canonical app path.

    Codex CLI 0.145.0 or newer must already be installed and available on PATH.
    Add ~/bin to PATH if the codex-cove command is not available in new shells.
  EOS
end
