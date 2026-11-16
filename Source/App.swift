import AppKit
import WebKit
import Foundation

final class LensDelegate:NSObject,NSApplicationDelegate,WKScriptMessageHandler,WKNavigationDelegate,NSWindowDelegate {
    var window:NSWindow!,web:WKWebView!,resources:URL!
    let engine=DiskEngine()
    let defaults=UserDefaults.standard
    func applicationDidFinishLaunching(_ notification:Notification){
        let menu=NSMenu(),appItem=NSMenuItem(),editItem=NSMenuItem();menu.addItem(appItem);menu.addItem(editItem)
        let appMenu=NSMenu();appItem.submenu=appMenu
        appMenu.addItem(withTitle:"关于空间镜",action:#selector(about),keyEquivalent:"")
        appMenu.addItem(.separator());appMenu.addItem(withTitle:"退出空间镜",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editMenu=NSMenu(title:"编辑");editItem.submenu=editMenu
        editMenu.addItem(withTitle:"复制",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        editMenu.addItem(withTitle:"粘贴",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        editMenu.addItem(withTitle:"全选",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        NSApp.mainMenu=menu
        defaults.register(defaults:["autoScan":true,"largeMinimum":104857600,"hashMinimum":1048576,"launchMode":"quick"])
        let config=WKWebViewConfiguration();config.userContentController.add(self,name:"diskLens")
        let css="body{padding:0!important;background:#fff!important}.shell{height:100vh!important;min-height:0!important;max-width:none!important;border:0!important;border-radius:0!important;box-shadow:none!important}.traffic{visibility:hidden}"
        let script="document.addEventListener('DOMContentLoaded',function(){const s=document.createElement('style');s.textContent="+String(data:try! JSONSerialization.data(withJSONObject:css,options:.fragmentsAllowed),encoding:.utf8)!+";document.head.appendChild(s);});"
        config.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentStart,forMainFrameOnly:true))
        web=WKWebView(frame:.zero,configuration:config);web.navigationDelegate=self
        let frame=NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1440,height:900)
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:min(1360,frame.width-64),height:min(880,frame.height-48)),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title="空间镜";window.titleVisibility = .hidden;window.titlebarAppearsTransparent=true;window.minSize=NSSize(width:1024,height:680)
        window.contentView=web;window.delegate=self;window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        resources=Bundle.main.resourceURL!
        web.loadFileURL(resources.appendingPathComponent("index.html"),allowingReadAccessTo:resources)
    }
    @objc func about(){let a=NSAlert();a.messageText="空间镜 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")";a.informativeText="快速检查与内部数据盘分析。停止后可在本次会话继续扫描；受保护项目标明原因并禁止勾选。";a.runModal()}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
    func moving()->Bool{engine.sync{["trashing","restoring"].contains(engine.phase)}}
    func operationNotice(){let a=NSAlert();a.messageText="文件操作尚未结束";a.informativeText="请等待移到废纸篓或恢复操作完成后再退出，以便保存完整记录。";a.addButton(withTitle:"继续等待");a.runModal()}
    func windowShouldClose(_ sender:NSWindow)->Bool{if moving(){operationNotice();return false};return true}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{if moving(){operationNotice();return .terminateCancel};return .terminateNow}
    func applicationWillTerminate(_ notification:Notification){engine.stop()}
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){
        guard let u=navigationAction.request.url,u.isFileURL,u.standardizedFileURL.path==resources.appendingPathComponent("index.html").path else{decisionHandler(.cancel);return};decisionHandler(.allow)
    }
    func reply(_ id:String,_ value:Any?=nil,error:String?=nil){
        let object:[String:Any]=["id":id,"result":value ?? NSNull(),"error":error as Any? ?? NSNull()]
        guard let data=try? JSONSerialization.data(withJSONObject:object),let json=String(data:data,encoding:.utf8)else{return}
        DispatchQueue.main.async{self.web.evaluateJavaScript("window.nativeReply(\(json))",completionHandler:nil)}
    }
    func preferences()->[String:Any]{
        var path=defaults.string(forKey:"scanRoot") ?? engine.home
        if !FileManager.default.fileExists(atPath:path){path=engine.home}
        return ["autoScan":defaults.bool(forKey:"autoScan"),"largeMinimum":defaults.integer(forKey:"largeMinimum"),"hashMinimum":defaults.integer(forKey:"hashMinimum"),"scanRoot":path,"launchMode":defaults.string(forKey:"launchMode") ?? "quick","lastMode":defaults.string(forKey:"lastScanMode") ?? "folder"]
    }
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage){
        guard message.frameInfo.isMainFrame,message.webView?.url?.isFileURL==true,message.webView?.url?.path==resources.appendingPathComponent("index.html").path,
              let body=message.body as? [String:Any],let id=body["id"] as? String,id.count<100,let route=body["route"] as? String else{return}
        let args=body["args"] as? [String:Any] ?? [:]
        switch route {
        case "preferences":reply(id,preferences());return
        case "setPreferences":
            if let v=args["autoScan"] as? Bool{defaults.set(v,forKey:"autoScan")}
            if let v=args["launchMode"] as? String,["quick","last"].contains(v){defaults.set(v,forKey:"launchMode")}
            for key in ["largeMinimum","hashMinimum"]{if let v=args[key] as? Int,v>=1,v<=1_099_511_627_776{defaults.set(v,forKey:key)}}
            reply(id,preferences());return
        case "choose":
            guard !engine.busy()else{reply(id,error:"请先停止当前检查。");return}
            let p=NSOpenPanel();p.canChooseDirectories=true;p.canChooseFiles=false;p.allowsMultipleSelection=false;p.message="选择要分析的文件夹。扫描只读取文件元数据，清理由你确认。"
            p.beginSheetModal(for:window){r in self.reply(id,["path":r == .OK ? p.url?.path as Any? ?? NSNull():NSNull()])};return
        case "reveal":
            do{let path=try engine.revealPath(id:args["id"] as? String ?? "",path:args["path"] as? String ?? "");NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)]);reply(id,["ok":true])}catch{reply(id,error:error.localizedDescription)};return
        case "systemSettings":NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/System Settings.app"));reply(id,["ok":true]);return
        case "trash":
            let ids=args["ids"] as? [String] ?? []
            do{
                try engine.checkRunningApps(ids);let preview=try engine.previewTrash(ids),items=preview["items"] as? [[String:Any]] ?? []
                let a=NSAlert();a.alertStyle = .warning;a.messageText="将 \(items.count) 个项目移到废纸篓？"
                a.informativeText=items.prefix(12).map{$0["path"] as? String ?? ""}.joined(separator:"\n")+(items.count>12 ? "\n…其余项目已在清理列表中显示。":"")+"\n\n可以在系统废纸篓恢复。本工具不会清空废纸篓，移动后通常不会立即释放磁盘空间。"
                a.addButton(withTitle:"取消");a.addButton(withTitle:"移到废纸篓")
                a.beginSheetModal(for:window){response in
                    guard response == .alertSecondButtonReturn else{self.reply(id,["cancelled":true]);return}
                    do{try self.engine.checkRunningApps(ids)}catch{self.reply(id,error:error.localizedDescription);return}
                    DispatchQueue.global(qos:.userInitiated).async{do{self.reply(id,try self.engine.trash(ids))}catch{self.reply(id,error:error.localizedDescription)}}
                }
            }catch{reply(id,error:error.localizedDescription)};return
        case "saveReport":
            let p=NSSavePanel();p.nameFieldStringValue="空间镜扫描报告.json";p.beginSheetModal(for:window){r in
                guard r == .OK,let u=p.url else{self.reply(id,["saved":false]);return}
                DispatchQueue.global().async{do{let report:[String:Any]=["summary":self.engine.status(),"largestFiles":self.engine.files(["minimum":100_000_000]),"history":self.engine.sync{self.engine.history}];let d=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);try d.write(to:u,options:.atomic);self.reply(id,["saved":true])}catch{self.reply(id,error:error.localizedDescription)}}
            };return
        default:break
        }
        DispatchQueue.global(qos:.userInitiated).async{
            do{
                let value:Any
                switch route {
                case "status":value=self.engine.status()
                case "scan":let path=args["path"] as? String ?? self.engine.home;let mode=args["mode"] as? String ?? "folder";try self.engine.start(path:path,mode:mode);if mode=="folder"{self.defaults.set(path,forKey:"scanRoot")};self.defaults.set(mode,forKey:"lastScanMode");value=["ok":true]
                case "stop":self.engine.stop();value=["ok":true]
                case "resume":try self.engine.resume();value=["ok":true]
                case "files":value=self.engine.files(args)
                case "directory":value=self.engine.directory(args["path"] as? String ?? "")
                case "hash":try self.engine.startHash(minimum:(args["minimum"] as? NSNumber)?.int64Value ?? 1_048_576);value=["ok":true]
                case "duplicates":value=self.engine.duplicateRows(offset:args["offset"] as? Int ?? 0)
                case "targets":value=self.engine.targetRows(category:args["category"] as? String ?? "")
                case "previewTrash":value=try self.engine.previewTrash(args["ids"] as? [String] ?? [])
                case "apps":value=self.engine.applicationRows()
                case "scanApps":try self.engine.startApps();value=["ok":true]
                case "docker":value=self.engine.dockerUsage()
                case "history":value=self.engine.sync{self.engine.history}
                case "restore":value=try self.engine.restore(args["id"] as? String ?? "")
                default:throw LensError("未知操作")
                }
                self.reply(id,value)
            }catch{self.reply(id,error:error.localizedDescription)}
        }
    }
}
