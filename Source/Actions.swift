import Foundation
import Darwin

struct PlannedItem {
    let id:String,path:String,size:Int64,directory:Bool,kind:String
    var json:[String:Any]{["id":id,"path":path,"name":URL(fileURLWithPath:path).lastPathComponent,"size":size,"directory":directory,"kind":kind]}
}
extension DiskEngine {
    func cacheRoot(for path:String)->String?{
        let build=home+"/Library/Developer/Xcode/DerivedData/"
        if path.hasPrefix(build),let part=path.dropFirst(build.count).split(separator:"/").first{return build+part}
        for suffix in ["Library/Caches/go-build",".cache/swe-batch/gobuild"]{let base=home+"/"+suffix;if within(path,base){return base}}
        let marker="/org.sparkle-project.Sparkle/Installation/"
        if within(path,home+"/Library/Caches"),let range=path.range(of:marker),let part=path[range.upperBound...].split(separator:"/").first{return String(path[..<range.upperBound])+part}
        let update=home+"/Library/Caches/BaiduMacHi/HiUpdate/"
        if path.hasPrefix(update),let part=path.dropFirst(update.count).split(separator:"/").first{return update+part}
        return nil
    }
    func allowedCacheTarget(_ path:String)->Bool{cacheRoot(for:path+"/placeholder")==path}
    func prepareManagedTargets(){
        let snapshot=sync{Array(records.values)},incomplete=isStopped(),issues=sync{errors},generation=sync{started}
        guard !incomplete else{return}
        var manifests:[String:[String:Stamp]]=[:],sizes:[String:Int64]=[:],cats:[String:String]=[:]
        for e in snapshot where ["updates","build"].contains(e.category){guard let base=cacheRoot(for:e.path),base != e.path else{continue};manifests[base,default:[:]][e.path]=e.stamp;sizes[base,default:0]+=e.size;cats[base]=e.category}
        for path in sync({managedCandidates}) where manifests[path]==nil{manifests[path]=[:];cats[path]=(path.contains("DerivedData")||path.contains("go-build")||path.contains("gobuild")) ? "build":"updates"}
        for (path,expected) in manifests{
            if isStopped(){break}
            if issues.contains(where:{within($0["path"] ?? "",path)}){continue}
            guard let s=try? info(path),s.st_mode&S_IFMT==S_IFDIR,allowedCacheTarget(path) else{continue}
            guard let fresh=try? inspectTree(path,allowLinks:true,interruptible:true),let after=try? info(path),Stamp(after)==Stamp(s) else{continue}
            guard expected.allSatisfy({fresh[$0.key]==$0.value}) else{continue}
            let id="target:"+UUID().uuidString
            let t=Target(id:id,path:path,kind:"cache",category:cats[path] ?? "build",stamp:Stamp(after),expected:fresh,size:fresh.values.reduce(Int64(0)){$0+$1.size})
            sync{if started==generation{targets[id]=t}}
        }
        sync{revision+=1}
    }
    func targetRows(category:String)->[[String:Any]]{sync{targets.values.filter{$0.kind=="cache" && (category.isEmpty||$0.category==category)}.sorted{$0.size>$1.size}.map(\.json)}}
    func inspectTree(_ path:String,allowLinks:Bool,interruptible:Bool=false)throws->[String:Stamp]{
        var expected:[String:Stamp]=[:],failure:Error?
        guard let en=fm.enumerator(at:URL(fileURLWithPath:path),includingPropertiesForKeys:nil,options:[],errorHandler:{_,e in failure=e;return false})else{throw LensError("无法检查目录：\(path)")}
        while let url=en.nextObject() as? URL{
            if interruptible,isStopped(){throw LensError("已停止")}
            let s=try info(url.path),type=s.st_mode&S_IFMT
            if type==S_IFLNK{guard allowLinks else{throw LensError("缓存中包含符号链接，请手动审核：\(url.path)")};expected[url.path]=Stamp(s);en.skipDescendants()}
            else if type==S_IFREG{guard s.st_flags & 0x40000000 == 0 else{throw LensError("目录包含未下载的云端文件")};expected[url.path]=Stamp(s)}
            else if type != S_IFDIR{throw LensError("目录包含特殊文件，已拒绝移动：\(url.path)")}
            if expected.count>maxFiles{throw LensError("目录过大，请使用系统文件管理器审核。")}
        }
        if let failure=failure{throw failure};return expected
    }
    func allowedAppTarget(_ path:String)->Bool{
        let u=URL(fileURLWithPath:path)
        return path.hasSuffix(".app") && ["/Applications",home+"/Applications"].contains(u.deletingLastPathComponent().path) && !within(Bundle.main.bundlePath,path)
    }
    func validateTarget(_ t:Target)throws{
        guard URL(fileURLWithPath:t.path).resolvingSymlinksInPath().path==t.path else{throw LensError("目录路径发生变化，请重新扫描。")}
        guard t.kind=="cache" ? allowedCacheTarget(t.path):allowedAppTarget(t.path) else{throw LensError("目录不在允许的清理范围。")}
        let s=try info(t.path);guard s.st_mode&S_IFMT==S_IFDIR,Stamp(s)==t.stamp else{throw LensError("目录已变化，请重新扫描：\(t.path)")}
        let fresh=try inspectTree(t.path,allowLinks:true)
        guard fresh==t.expected else{throw LensError("目录内容已变化，请重新扫描后再清理：\(t.path)")}
    }
    func plan(_ ids:[String])throws->[PlannedItem]{try sync{
        guard !busy(),appPhase != "scanning" else{throw LensError("请先等待当前检查结束。")}
        let unique=Set(ids);guard !unique.isEmpty,unique.count<=200 else{throw LensError("每次请选择 1 至 200 项。")}
        var items:[PlannedItem]=[]
        for id in unique{
            if let e=records[id]{guard !e.keep else{throw LensError("不能清理受保护文件：\(e.path)")};items.append(PlannedItem(id:id,path:e.path,size:e.size,directory:false,kind:"file"))}
            else if let t=targets[id]{items.append(PlannedItem(id:id,path:t.path,size:t.size,directory:true,kind:t.kind))}
            else{throw LensError("选择项已过期，请重新选择。")}
        }
        items.sort{$0.path.count<$1.path.count};var collapsed:[PlannedItem]=[]
        for item in items{if !collapsed.contains(where:{$0.directory&&within(item.path,$0.path)}){collapsed.append(item)}}
        let grouped=groups.flatMap{g in g.ids.compactMap{records[$0]}}
        let selectedIDs=Set(grouped.filter{e in collapsed.contains{$0.id==e.id||($0.directory&&within(e.path,$0.path))}}.map(\.id))
        for g in groups where !Set(g.ids).isDisjoint(with:selectedIDs){let survivors=g.ids.filter{!selectedIDs.contains($0)}.compactMap{records[$0]};guard survivors.contains(where:{unchanged($0)}) else{throw LensError("每组重复文件至少保留一份未变化的原件。")}}
        return collapsed
    }}
    func previewTrash(_ ids:[String])throws->[String:Any]{let items=try plan(ids);return ["items":items.map(\.json),"size":items.reduce(Int64(0)){$0+$1.size},"count":items.count]}
    func trash(_ ids:[String])throws->[String:Any]{
        let planned=try plan(ids),prior=sync{phase},before=(disk()["free"] as? Int64) ?? 0
        try sync{
            guard !busy() else{throw LensError("当前操作尚未结束")}
            phase="trashing"
        }
        defer{sync{phase=prior;revision+=1}}
        var moved:[[String:Any]]=[],failed:[[String:Any]]=[]
        for item in planned{
            do{
                if item.directory{guard let t=sync({targets[item.id]})else{throw LensError("目录选择已过期")};try validateTarget(t)}
                else{guard let e=sync({records[item.id]})else{throw LensError("文件选择已过期")};try validate(e)
                    if let gid=e.group{let selected=Set(planned.map(\.id));let good=sync{records.values.contains{$0.group==gid && !selected.contains($0.id) && unchanged($0)}};guard good else{throw LensError("保留副本已变化，已跳过此文件。")}}
                }
                var destination:NSURL?
                try fm.trashItem(at:URL(fileURLWithPath:item.path),resultingItemURL:&destination)
                guard !fm.fileExists(atPath:item.path) else{throw LensError("文件仍在原位置，请检查。")}
                var row=item.json;row["destination"]=destination?.path ?? "";row["restored"]=false
                if let p=destination?.path,let s=try? info(p){row["trashInode"]=String(s.st_ino);row["trashModified"]=String(Stamp(s).mtime);row["trashSize"]=s.st_size}
                moved.append(row)
                sync{
                    let removed=records.values.filter{$0.path==item.path || (item.directory&&within($0.path,item.path))}
                    if item.directory{let category=targets[item.id]?.category ?? "protected";subtractDirectory(item.path,category:category=="apps" ? "protected":category)}
                    for e in removed{records.removeValue(forKey:e.id);pathIDs.removeValue(forKey:e.path);if !item.directory{totalBytes-=e.size;scannedFiles-=1;if !e.hardlink{allocatedBytes=max(0,allocatedBytes-e.allocated)};addFolder(e,delta:-1);buckets[e.category]?.logical-=e.size;buckets[e.category]?.allocated-=e.allocated;buckets[e.category]?.count-=1}}
                    if item.directory{for key in Array(folders.keys) where within(key,item.path){folders.removeValue(forKey:key);folderChildren.removeValue(forKey:key);fileChildren.removeValue(forKey:key);directCounts.removeValue(forKey:key)};folderChildren[(item.path as NSString).deletingLastPathComponent]?.remove(item.path)}
                    for key in Array(targets.keys){if let t=targets[key],within(t.path,item.path){targets.removeValue(forKey:key)}}
                    if item.kind=="app"{appRows.removeAll{$0["id"] as? String==item.id}}
                }
            }catch{failed.append(["path":item.path,"error":error.localizedDescription])}
        }
        sync{
            groups=groups.compactMap{g in var x=g;x.ids=x.ids.filter{records[$0] != nil};if x.ids.count<2{for id in x.ids{records[id]?.group=nil};return nil};return x}
            if !moved.isEmpty{needsRescan=true;invalidateResume()}
            let after=(disk()["free"] as? Int64) ?? before
            history.insert(["id":UUID().uuidString,"date":Date().timeIntervalSince1970,"moved":moved,"failed":failed,"size":moved.reduce(Int64(0)){$0+($1["size"] as? Int64 ?? 0)},"freeBefore":before,"freeAfter":after],at:0)
            if history.count>200{history=Array(history.prefix(200))}
        }
        saveHistory()
        return ["moved":moved,"failed":failed,"note":"已移到系统废纸篓，可以恢复。清空前通常不会释放磁盘空间。"]
    }
    func restore(_ historyID:String)throws->[String:Any]{
        let prior=try sync{()->String in guard !busy(),appPhase != "scanning" else{throw LensError("请等待当前操作结束。")};let p=phase;phase="restoring";return p}
        defer{sync{phase=prior;revision+=1}}
        guard let index=sync({history.firstIndex{$0["id"] as? String==historyID}}) else{throw LensError("记录不存在")}
        var items=sync{history[index]["moved"] as? [[String:Any]] ?? []};var restored=0,failed:[[String:String]]=[]
        for i in items.indices where items[i]["restored"] as? Bool != true{
            do{
                guard let origin=items[i]["path"] as? String,let dest=items[i]["destination"] as? String,!dest.isEmpty,!isSystem(origin),dest.split(separator:"/").contains(where:{$0==".Trash"||$0==".Trashes"}) else{throw LensError("无法通过 App 恢复，请在系统废纸篓中查看。")}
                guard !fm.fileExists(atPath:origin),fm.fileExists(atPath:URL(fileURLWithPath:origin).deletingLastPathComponent().path) else{throw LensError("原路径已有文件或父目录已不存在，未覆盖任何文件。")}
                guard URL(fileURLWithPath:origin).resolvingSymlinksInPath().path==origin,URL(fileURLWithPath:dest).resolvingSymlinksInPath().path==dest else{throw LensError("恢复路径已变化，请在 Finder 中手动恢复。")}
                let s=try info(dest)
                guard String(s.st_ino)==items[i]["trashInode"] as? String,String(Stamp(s).mtime)==items[i]["trashModified"] as? String else{throw LensError("废纸篓中的项目已变化，请在 Finder 中恢复。")}
                try fm.moveItem(atPath:dest,toPath:origin);items[i]["restored"]=true;restored+=1
            }catch{failed.append(["path":items[i]["path"] as? String ?? "","error":error.localizedDescription])}
        }
        sync{history[index]["moved"]=items;if restored>0{needsRescan=true;invalidateResume()};revision+=1};saveHistory()
        return ["restored":restored,"failed":failed]
    }
    func revealPath(id:String,path:String)throws->String{
        try sync{
            if let e=records[id]{guard fm.fileExists(atPath:e.path)else{throw LensError("文件已不存在")};return e.path}
            if let t=targets[id]{return t.path}
            guard !path.isEmpty,folders[path] != nil||path==root||path==home else{throw LensError("只能定位当前扫描范围中的项目。")};return path
        }
    }
}
