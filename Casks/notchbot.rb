cask "notchbot" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

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
