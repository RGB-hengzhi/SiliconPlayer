import Foundation
import CMPV
import Darwin
import PlayerCore

/// One synchronous setter owns all buffers. No shell, file-list delimiter or
/// raw mpv filter-list string parser processes imported file paths.
@MainActor enum VideoAssetMPVNode {
    private final class Storage {
        var strings:[UnsafeMutablePointer<CChar>]=[]
        var values:[(UnsafeMutablePointer<mpv_node>,Int)]=[]
        var keys:[(UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,Int)]=[]
        var lists:[UnsafeMutablePointer<mpv_node_list>]=[]
        func text(_ value:String) throws -> mpv_node {
            guard value.utf8.count<=1_048_576,!value.utf8.contains(0),let pointer=strdup(value) else {throw VideoAssetError.invalidDocument}
            strings.append(pointer)
            var node=mpv_node();node.format=MPV_FORMAT_STRING;node.u.string=pointer;return node
        }
        func list(_ nodes:[mpv_node],names:[String]?=nil) throws -> mpv_node {
            guard nodes.count<=16,names==nil || names!.count==nodes.count else {throw VideoAssetError.invalidDocument}
            let pointer=UnsafeMutablePointer<mpv_node>.allocate(capacity:max(1,nodes.count))
            for (i,node) in nodes.enumerated() {pointer.advanced(by:i).initialize(to:node)}
            values.append((pointer,nodes.count))
            var namePointer:UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
            if let names {
                let allocated=UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity:max(1,names.count))
                keys.append((allocated,0))
                for (i,name) in names.enumerated() {
                    let stringNode=try text(name)
                    allocated.advanced(by:i).initialize(to:stringNode.u.string)
                    keys[keys.count-1].1 += 1
                }
                namePointer=allocated
            }
            let native=UnsafeMutablePointer<mpv_node_list>.allocate(capacity:1)
            native.initialize(to:mpv_node_list(num:Int32(nodes.count),values:pointer,keys:namePointer))
            lists.append(native)
            var node=mpv_node();node.format=names==nil ? MPV_FORMAT_NODE_ARRAY : MPV_FORMAT_NODE_MAP;node.u.list=native;return node
        }
        deinit {
            for (p,n) in values {p.deinitialize(count:n);p.deallocate()}
            for (p,n) in keys {p.deinitialize(count:n);p.deallocate()}
            for p in lists {p.deinitialize(count:1);p.deallocate()}
            for p in strings {free(p)}
        }
    }
    static func shaders(_ paths:[String],handle:OpaquePointer) throws -> Int32 {
        guard paths.count<=12,paths.allSatisfy({$0.hasPrefix("/") && $0.utf8.count<=4096}) else {throw VideoAssetError.invalidSource}
        let storage=Storage()
        var root=try storage.list(paths.map {try storage.text($0)})
        return mpv_set_property(handle,"glsl-shaders",MPV_FORMAT_NODE,&root)
    }
    static func lavfi(_ graph:String,handle:OpaquePointer) throws -> Int32 {
        let storage=Storage()
        var entries:[mpv_node]=[]
        if !graph.isEmpty {
            let params=try storage.list([storage.text(graph)],names:["graph"])
            let filter=try storage.list([storage.text("lavfi"),params],names:["name","params"])
            entries=[filter]
        }
        var root=try storage.list(entries)
        return mpv_set_property(handle,"vf",MPV_FORMAT_NODE,&root)
    }
}
