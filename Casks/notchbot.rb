cask "notchbot" do
  version "1.0.0"
  sha256 "d0a0909695488cb34cc8e4c4799aa3f6407fa604f2468254b3888873dac5d668"

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
