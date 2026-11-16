import Foundation
import AppKit
import Darwin

extension DiskEngine {
    func startApps()throws{
        try sync{guard !busy(),appPhase != "scanning" else{throw LensError("请先等待文件扫描结束，再统计应用。")};appPhase="scanning";appRows=[];stopped=false;targets=targets.filter{$0.value.kind != "app"}}
        DispatchQueue.global(qos:.utility).async{
            let dirs=["/Applications",self.home+"/Applications"]
            for directory in dirs{
                if self.isStopped(){break}
                guard let children=try? self.fm.contentsOfDirectory(at:URL(fileURLWithPath:directory),includingPropertiesForKeys:nil) else{continue}
                for app in children where app.pathExtension=="app"{
                    if self.isStopped(){break}
                    do{
                        guard app.resolvingSymlinksInPath().path==app.path else{continue}
                        let bundle=Bundle(url:app),name=(bundle?.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String) ?? (bundle?.object(forInfoDictionaryKey:"CFBundleName") as? String) ?? app.deletingPathExtension().lastPathComponent
                        let identifier=bundle?.bundleIdentifier ?? ""
                        let manifest=try self.inspectTree(app.path,allowLinks:true,interruptible:true),s=try self.info(app.path)
                        let size=manifest.values.reduce(Int64(0)){$0+$1.size},id="app:"+UUID().uuidString
                        var related:[[String:Any]]=[]
                        if !identifier.isEmpty{
                            for suffix in ["Library/Caches/"+identifier,"Library/Preferences/"+identifier+".plist","Library/Saved Application State/"+identifier+".savedState","Library/Application Support/"+identifier]{
                                let path=self.home+"/"+suffix
                                if let st=try? self.info(path){
                                    let bytes:Int64
                                    if st.st_mode&S_IFMT==S_IFDIR{bytes=(try? self.inspectTree(path,allowLinks:true).values.reduce(Int64(0)){$0+$1.size}) ?? -1}else{bytes=st.st_size}
                                    related.append(["path":path,"size":bytes,"keep":true])
                                }
                            }
                        }
                        let target=Target(id:id,path:app.path,kind:"app",category:"apps",stamp:Stamp(s),expected:manifest,size:size)
                        let row:[String:Any]=["id":id,"name":name,"path":app.path,"bundleID":identifier,"size":size,"related":related,"relatedSize":related.reduce(Int64(0)){$0+max(0,$1["size"] as? Int64 ?? 0)},"modified":Double(s.st_mtimespec.tv_sec),"version":bundle?.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "","canTrash":self.allowedAppTarget(app.path)]
                        self.sync{self.targets[id]=target;self.appRows.append(row);self.revision+=1}
                    }catch{self.problem(app.path,"应用统计失败："+error.localizedDescription)}
                }
            }
            self.sync{self.appRows.sort{($0["size"] as? Int64 ?? 0)>($1["size"] as? Int64 ?? 0)};self.appPhase=self.stopped ? "cancelled":"done";self.revision+=1}
        }
    }
    func applicationRows()->[String:Any]{sync{["phase":appPhase,"items":appRows]}}
    func checkRunningApps(_ ids:[String])throws{
        let selected=sync{ids.compactMap{targets[$0]}.filter{$0.kind=="app"}}
        for t in selected{
            if NSWorkspace.shared.runningApplications.contains(where:{a in guard let path=a.bundleURL?.path else{return false};return within(path,t.path)}){
                throw LensError("请先退出“\(URL(fileURLWithPath:t.path).deletingPathExtension().lastPathComponent)”再卸载。")
            }
        }
    }
    func dockerUsage()->[String:Any]{
        let candidates=["/usr/local/bin/docker","/opt/homebrew/bin/docker","/Applications/Docker.app/Contents/Resources/bin/docker"]
        guard let binary=candidates.first(where:{fm.isExecutableFile(atPath:$0)}) else{return ["available":false,"output":"未找到 Docker 命令。可以在 Finder 中查看存储位置；本工具不会直接删除 Docker 虚拟磁盘。"]}
        let p=Process(),pipe=Pipe();p.executableURL=URL(fileURLWithPath:binary);p.arguments=["system","df","-v"];p.standardOutput=pipe;p.standardError=pipe
        var output=Data();let dataLock=NSLock()
        pipe.fileHandleForReading.readabilityHandler={handle in let data=handle.availableData;if !data.isEmpty{dataLock.lock();if output.count<2_000_000{output.append(data.prefix(2_000_000-output.count))};dataLock.unlock()}}
        do{
            try p.run();let timeout=DispatchWorkItem{if p.isRunning{p.terminate()}};DispatchQueue.global().asyncAfter(deadline:.now()+15,execute:timeout);p.waitUntilExit();timeout.cancel();pipe.fileHandleForReading.readabilityHandler=nil
            dataLock.lock();let text=String(data:output,encoding:.utf8) ?? "";dataLock.unlock()
            return ["available":p.terminationStatus==0,"output":text.isEmpty ? "Docker 未返回统计；请确认 Docker Desktop 已启动。":text]
        }catch{pipe.fileHandleForReading.readabilityHandler=nil;return ["available":false,"output":error.localizedDescription]}
    }
}
