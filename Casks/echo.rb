cask "echo" do
  version "1.5.0"
  sha256 "986068caf6a5f43c6a651a040994157ce840dcf13399173e2e39d7ab6ad1a972"

  url "https://github.com/alexiscreuzot/echo/releases/download/v#{version}/Echo.zip"
  name "Echo"
  desc "Send a specific app's audio into the iOS Simulator"
  homepage "https://github.com/alexiscreuzot/echo"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "Echo.app"

  zap trash: "~/Library/Preferences/com.alexiscreuzot.echo.plist"
end
