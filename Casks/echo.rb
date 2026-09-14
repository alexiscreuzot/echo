cask "echo" do
  version "1.0.0"
  sha256 "d0ee2c4ce600bb93464a72dbb0827e0c0c30150b8c8a59c002185d86e97004a0"

  url "https://github.com/alexiscreuzot/echo/releases/download/v#{version}/Echo.zip"
  name "Echo"
  desc "Send a specific app's audio into the iOS Simulator"
  homepage "https://github.com/alexiscreuzot/echo"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :tahoe"

  app "Echo.app"

  zap trash: "~/Library/Preferences/com.alexiscreuzot.echo.plist"
end
