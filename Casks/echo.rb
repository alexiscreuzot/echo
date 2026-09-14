cask "echo" do
  version "1.1.0"
  sha256 "c8408a5dff50af075332e57a8e8cb1ed66a406cc08d39e54794a89ca8173d93b"

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
