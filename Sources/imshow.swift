import Foundation
import AppKit

struct WindowPosition {
	let x: CGFloat
	let y: CGFloat
}

class Del: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ aNotification: Notification) {
		let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
		imageView.image = image
		imageView.imageScaling = .scaleNone
		
		let frame = NSRect(x: position.x, y: position.y, width: image.size.width, height: image.size.height)
		
		// Add key event handler
		class KeyEventWindow: NSPanel {
			override func keyDown(with event: NSEvent) {
				// Stop the runloop. Does not exit the process.
				NSApp.stop(nil)
			}
		}
		
		let keyWindow = KeyEventWindow(contentRect: frame, styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .borderless], backing: .buffered, defer: false)
		keyWindow.titlebarAppearsTransparent = true
		keyWindow.level = .tornOffMenu
		
		keyWindow.contentView = imageView
		keyWindow.setFrame(NSRect(x: position.x, y: position.y, width: keyWindow.frame.width, height: keyWindow.frame.height), display: true)
		keyWindow.makeKeyAndOrderFront(nil)
		
		NSApplication.shared.activate(ignoringOtherApps: true)
	}
	init(for image: NSImage, position: WindowPosition) {
		
		self.image = image
		self.position = position
		super.init()
	}
	var image: NSImage
	var position: WindowPosition
}

@MainActor
func showDiagnosticWindow(for image: NSImage, position: WindowPosition) {
	let app = NSApplication.shared
	let delegate = Del(for: image, position: position)
	app.delegate = delegate
	app.setActivationPolicy(.accessory)
	
	_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}

@main
struct Imshow {
	var args: [String]
	var isBackgroundMode: Bool
	var isDiagnosticMode: Bool

	static func main() async {
		let args = ProcessInfo.processInfo.arguments
		let imshow = Imshow(args: args, isBackgroundMode: args.contains("-b"), isDiagnosticMode: args.contains("-d"))
		await imshow.run()
	}
	
	func printDiagnostic(_ string: String) {
		if isDiagnosticMode {
			print(string)
		}
	}
	
	@MainActor
	func run() async {
		
		if !isBackgroundMode {
			exit(immediate())
		}
		
		print("Running in blocking mode")
		
		// Blocking mode: show the image
		let image: NSImage
		let position: WindowPosition
		
		// Parse position from arguments
		if let xStr = args.first(where: { $0.hasPrefix("-x=") })?.dropFirst(3),
		   let yStr = args.first(where: { $0.hasPrefix("-y=") })?.dropFirst(3),
		   let x = Double(xStr),
		   let y = Double(yStr) {
			position = WindowPosition(x: x, y: y)
			print("Using provided position: x=\(x), y=\(y)")
		} else {
			// Default to center if no position provided
			if let screen = NSScreen.main {
				let screenRect = screen.visibleFrame
				position = WindowPosition(
					x: screenRect.midX,
					y: screenRect.midY
				)
				print("Using default centered position: x=\(position.x), y=\(position.y)")
				
			} else {
				position = WindowPosition(x: 0, y: 0)
				print("No screen found, using position: x=0, y=0")
			}
		}
		
		let stdinData = FileHandle.standardInput.readDataToEndOfFile()
		if let loadedImage = NSImage(data: stdinData) {
			image = loadedImage
			print("Successfully loaded image in background mode, size: \(loadedImage.size)")
		} else {
			print("Could not load image")
			exit(1)
		}
		
		showDiagnosticWindow(for: image, position: position)
	}
	
	func immediate() -> Int32 {
		// Handle file arguments
		let fileArgs = args.dropFirst().filter { !$0.hasPrefix("-") }
		
		// Print usage if no arguments provided
		if fileArgs.isEmpty && isatty(STDIN_FILENO) != 0 {
			print("""
			Usage: imshow [image_path...] [-d]
			
			Display one or more images in separate windows.
			If no image paths are provided, reads image data from stdin.
			-d: Enable diagnostic mode
			""")
			exit(1)
		}
		
		// Get the size of the first image for positioning
		var firstImageSize: NSSize?
		var returnStatus: Int32 = 0
		var imagesData: [Data] = []
		
		// Handle stdin if no file arguments
		if fileArgs.isEmpty {
			let stdinData = FileHandle.standardInput.readDataToEndOfFile()
			if let img = NSImage(data: stdinData) {
				firstImageSize = img.size
				printDiagnostic("Successfully loaded image from stdin, size: \(img.size)")
			} else {
				printDiagnostic("Failed to load image from stdin")
			}
			imagesData.append(stdinData)
		} else {
			// Handle file arguments
			for (_, filePath) in fileArgs.enumerated() {
				guard let image = NSImage(contentsOfFile: filePath) else {
					print("Error: Could not load image from \(filePath)")
					returnStatus = 1
					continue
				}
				printDiagnostic("Successfully loaded image from \(filePath), size: \(image.size)")
				
				guard let imageData = image.tiffRepresentation else {
					print("Error: Could not prepare representation for transport \(filePath)")
					returnStatus = 1
					continue
				}
				
				imagesData.append(imageData)
				if firstImageSize == nil {
					firstImageSize = image.size
				}
			}
		}
		
		guard let firstImageSize else {
			printDiagnostic("No valid images found to display")
			return(1)
		}
		
		// Calculate window positions
		let positions = calculateWindowPositions(count: fileArgs.isEmpty ? 1 : fileArgs.count, windowSize: firstImageSize)
		zip(imagesData, positions).forEach { data, position in
			do {
				try spawnBackgroundProcess(with: data, executablePath: args[0], position: position, isDiagnosticMode: isDiagnosticMode)
			} catch {
				printDiagnostic("Failed to spawn background process: \(error)")
				returnStatus = 1
			}
		}
		return returnStatus
	}
	
	private func calculateWindowPositions(count: Int, windowSize: NSSize) -> [WindowPosition] {
		guard let screen = NSScreen.main else { return [WindowPosition(x: 0, y: 0)] }
		let screenRect = screen.visibleFrame
		
		// Constants for window positioning
		let offsetX: CGFloat = 20
		let offsetY: CGFloat = 20
		
		// Calculate the starting position to center the group
		let totalOffsetX = CGFloat(count - 1) * offsetX
		let totalOffsetY = CGFloat(count - 1) * offsetY
		
		// Center the first window, then offset subsequent windows
		let startX = screenRect.midX - windowSize.width / 2 - totalOffsetX
		let startY = screenRect.midY - windowSize.height / 2 + totalOffsetY
		
		var positions: [WindowPosition] = []
		
		// Create diagonal cascade
		for i in 0..<count {
			let x = startX + CGFloat(i) * offsetX
			let y = startY - CGFloat(i) * offsetY
			positions.append(WindowPosition(x: x, y: y))
		}
		
		return positions
	}

	private func spawnBackgroundProcess(with data: Data, executablePath: String, position: WindowPosition, isDiagnosticMode: Bool) throws {
		let process = Process()
		
		
		if !isDiagnosticMode {
			process.standardOutput = FileHandle.nullDevice
			process.standardError = FileHandle.nullDevice
		}
		
		process.executableURL = URL(fileURLWithPath: executablePath)
		process.arguments = ["-b", "-x=\(position.x)", "-y=\(position.y)"]
		
		printDiagnostic("Spawning background process at position: x=\(position.x), y=\(position.y)")
		printDiagnostic("Executable path: \(executablePath)")
		
		let pipe = Pipe()
		process.standardInput = pipe
		
		try process.run()
		pipe.fileHandleForWriting.write(data)
		pipe.fileHandleForWriting.closeFile()
	}
}
