import AppKit

@main
enum EchoMain {
    static func main() {
        if ScreenshotRenderer.isActive {
            ScreenshotRenderer.main()
        } else {
            EchoApp.main()
        }
    }
}
