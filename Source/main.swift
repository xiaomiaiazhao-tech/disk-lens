import AppKit
import Foundation

let arguments=CommandLine.arguments
if arguments.contains("--help") {
    print("""
    空间镜 / DiskLens
    Double-click the app for the graphical interface.
    Read-only metadata inspection:
      DiskLens --inspect PATH [--quick | --disk] [--seconds N] [--hash]
    --disk inspects the accessible internal Data volume, not every mounted volume.
    --hash reads eligible file contents for duplicate detection.
    No command-line deletion command is provided.
    """)
} else if arguments.contains("--version") {
    print(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "development")
} else if let i=arguments.firstIndex(of:"--inspect"),arguments.count>i+1 {
    do {
        let engine=DiskEngine(persist:false)
        let mode=arguments.contains("--disk") ? "disk":arguments.contains("--quick") ? "quick":"folder"
        try engine.start(path:arguments[i+1],mode:mode)
        if let t=arguments.firstIndex(of:"--seconds"),arguments.count>t+1,let seconds=Double(arguments[t+1]),seconds>0 {
            DispatchQueue.global().asyncAfter(deadline:.now()+seconds){engine.stop()}
        }
        while engine.busy(){Thread.sleep(forTimeInterval:0.1)}
        if arguments.contains("--hash"){try engine.startHash(minimum:1_048_576);while engine.busy(){Thread.sleep(forTimeInterval:0.1)}}
        let data=try JSONSerialization.data(withJSONObject:engine.status(),options:[.prettyPrinted,.sortedKeys])
        print(String(data:data,encoding:.utf8)!)
    } catch {fputs("ERROR: \(error.localizedDescription)\n",stderr);exit(1)}
} else {
    let app=NSApplication.shared,delegate=LensDelegate()
    app.delegate=delegate;app.setActivationPolicy(.regular);app.run()
}
