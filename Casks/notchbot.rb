cask "notchbot" do
  version "1.0.1"
  sha256 "e5c0eb955ede1d4234a1a39ffb3a1a737bb774b399a5d150d6b896d7a94af8a0"

  url "https://github.com/scorp84/NotchBot/releases/download/v#{version}/NotchBot-#{version}.dmg"
  name "NotchBot"
  desc "Coding agents, living in the MacBook notch"
  homepage "https://github.com/scorp84/NotchBot"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "NotchBot.app"

  zap trash: [
    "~/.notchbot",
    "~/Library/Preferences/com.florian.notchbot.plist",
  ]
end
