cask "notchbot" do
  version "1.0.2"
  sha256 "fd6d6d02387ec2dd39323c46f898e6e222de279ca5057933841d1a2ea8ed47bd"

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
