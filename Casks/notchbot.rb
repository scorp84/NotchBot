cask "notchbot" do
  version "1.0.0"
  sha256 "d5f9863035001adb447ee04db43f82e1abf5d9782a49c81be68cffdebfba30bf"

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
