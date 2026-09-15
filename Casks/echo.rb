cask "echo" do
  version "1.2.0"
  sha256 "964697463cecfe2310bdc4119f0c9c03048ea72b14077d045166345730a6c26c"

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
