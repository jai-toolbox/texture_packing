#import "File";
#import "File_Utilities";
#import "Hash_Table";
#import "String";
#import "Basic";

#import "tbx/serialize";

/*

In computer programming, a manifest file is a file containing metadata for a group of accompanying files that are part of a set or coherent unit. For example, the files of a computer program may have a manifest describing the name, version number, license and the constituent files of the program.[1] The term "manifest" is borrowed from a cargo shipping procedure, where a ship manifest would list the crew and/or cargo of a vessel. 

We use modification time as "file has changed", note that this is not necessarily true, ie you modify a file by replacing it with itself, but it's much cheaper to set this up then full checksumming.

*/

Texture_File_Record :: struct {
    path: string;
    modification_time_low:  u64;
    modification_time_high: s64;
}

Texture_Pack_Manifest :: struct {
    records: [..] Texture_File_Record;
}

MANIFEST_PATH :: "data/packed_textures/pack_manifest.metadata";

should_repack :: (current_paths: [..] string) -> bool {

    manifest_string, manifest_ok := read_entire_file(MANIFEST_PATH);
    if !manifest_ok {
        log("No pack manifest found, repacking.");
        return true;
    }

    old_manifest, deserialize_ok := from_string(manifest_string, Texture_Pack_Manifest);
    if !deserialize_ok {
        log("Failed to deserialize pack manifest repacking.");
        return true;
    }

    // old records keyed by path
    old_records: Table(string, Texture_File_Record);
    for old_manifest.records {
        table_add(*old_records, it.path, it);
    }

    // note if you delete and add a file then this won't catch that.
    if current_paths.count != old_manifest.records.count {
        log("File count changed (% vs %) repacking.", current_paths.count, old_manifest.records.count);
        return true;
    }

    for current_paths {
        mod_low, mod_high := file_modtime_parts(it);

        old_record, found := table_find(*old_records, it);
        if !found {
            log("New file detected: '%' repacking.", it);
            return true;
        }

        if mod_low != old_record.modification_time_low || mod_high != old_record.modification_time_high {
            log("Modified file detected: '%' repacking.", it);
            return true;
        }
    }

    // check if any packed texture no longer exists anymore
    current_set: Table(string, bool);
    for current_paths  table_add(*current_set, it, true);

    for old_manifest.records {
        _, found := table_find(*current_set, it.path);
        if !found {
            log("Deleted file detected: '%' — repacking.", it.path);
            return true;
        }
    }

    log("All textures up to date skipping repack.");
    return false;
}

file_modtime_parts :: (path: string) -> u64, s64 {
    modtime, size, ok := file_modtime_and_size(path);
    if !ok return 0, 0;
    return modtime.low, modtime.high;
}

save_pack_manifest :: (texture_paths: [] string) {
    manifest: Texture_Pack_Manifest;

    for texture_paths {
        record: Texture_File_Record;
        record.path = it;
        record.modification_time_low, record.modification_time_high = file_modtime_parts(it);
        array_add(*manifest.records, record);
    }

    manifest_string, ok := struct_to_string_pretty(manifest);
    if ok {
        write_entire_file(MANIFEST_PATH, manifest_string);
        log("Wrote pack manifest: % (% entries)", MANIFEST_PATH, manifest.records.count);
    } else {
        log_error("Failed to serialize pack manifest");
    }
}
