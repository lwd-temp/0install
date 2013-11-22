(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Interacting with distribution package managers. *)

open General
open Support
open Support.Common
module FeedAttr = Constants.FeedAttr
module U = Support.Utils
module Q = Support.Qdom

open Distro

let generic_distribution slave =
  object
    inherit Distro.python_fallback_distribution slave "Distribution" []
    val check_host_python = true
    val distro_name = "fallback"
    val id_prefix = "package:fallback"
  end

let try_cleanup_distro_version_warn version package_name =
  match Versions.try_cleanup_distro_version version with
  | None -> log_warning "Can't parse distribution version '%s' for package '%s'" version package_name; None
  | Some version -> Some (Versions.parse_version version)

(** A simple cache for storing key-value pairs on disk. Distributions may wish to use this to record the
    version(s) of each distribution package currently installed. *)
module Cache =
  struct

    type cache_data = {
      mutable mtime : float;
      mutable size : int;
      mutable rev : int;
      mutable contents : (string, string) Hashtbl.t;
    }

    let re_colon_space = Str.regexp_string ": "

    (* Manage the cache named [cache_leaf]. Whenever [source] changes, everything in the cache is assumed to be invalid.
       Note: [format_version] doesn't make much sense. If the format changes, just use a different [cache_leaf],
       otherwise you'll be fighting with other versions of 0install.
       The [old_format] used different separator characters.
       *)
    class cache (config:General.config) (cache_leaf:string) (source:filepath) (format_version:int) ~(old_format:bool) =
      let warned_missing = ref false in
      let re_metadata_sep = if old_format then re_colon_space else U.re_equals
      and re_key_value_sep = if old_format then U.re_tab else U.re_equals
      in
      object (self)
        (* The status of the cache when we loaded it. *)
        val data = { mtime = 0.0; size = -1; rev = -1; contents = Hashtbl.create 10 }

        val cache_path = Basedir.save_path config.system (config_site +/ config_prog) config.basedirs.Basedir.cache +/ cache_leaf

        (** Reload the values from disk (even if they're out-of-date). *)
        method private load_cache =
          data.mtime <- -1.0;
          data.size <- -1;
          data.rev <- -1;
          Hashtbl.clear data.contents;

          if Sys.file_exists cache_path then (
            cache_path |> config.system#with_open_in [Open_rdonly; Open_text] (fun ch ->
              let headers = ref true in
              while !headers do
                match input_line ch with
                | "" -> headers := false
                | line ->
                    (* log_info "Cache header: %s" line; *)
                    match Utils.split_pair re_metadata_sep line with
                    | ("mtime", mtime) -> data.mtime <- float_of_string mtime
                    | ("size", size) -> data.size <- U.safe_int_of_string size
                    | ("version", rev) when old_format -> data.rev <- U.safe_int_of_string rev
                    | ("format", rev) when not old_format -> data.rev <- U.safe_int_of_string rev
                    | _ -> ()
              done;

              try
                while true do
                  let line = input_line ch in
                  let (key, value) = Utils.split_pair re_key_value_sep line in
                  Hashtbl.add data.contents key value   (* note: adds to existing list of packages for this key *)
                done
              with End_of_file -> ()
            )
          )

        (** Add some entries to the cache.
         * Warning: adding the empty list has no effect. In particular, future calls to [get] will still call [if_missing].
         * So if you want to record the fact that a package is not installed, you see need to add an entry for it (e.g. [["-"]]). *)
        method private put key values =
          try
            cache_path |> config.system#with_open_out [Open_append; Open_creat] ~mode:0o644 (fun ch ->
              values |> List.iter (fun value ->
                output_string ch @@ Printf.sprintf "%s=%s" key value;
                Hashtbl.add data.contents key value
              )
            )
          with Safe_exception _ as ex -> reraise_with_context ex "... writing cache %s: %s=%s" cache_path key (String.concat ";" values)

        (** Check cache is still up-to-date (i.e. that [source] hasn't changed). Clear it if not. *)
        method private ensure_valid =
          match config.system#stat source with
          | None ->
              if not !warned_missing then (
                log_warning "Package database '%s' missing!" source;
                warned_missing := true
              )
          | Some info ->
              let flush () =
                cache_path |> config.system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
                  let mtime = Int64.of_float info.Unix.st_mtime |> Int64.to_string in
                  if old_format then
                    Printf.fprintf ch "mtime: %s\nsize: %d\nformat: %d\n\n" mtime info.Unix.st_size format_version
                  else
                    Printf.fprintf ch "mtime=%s\nsize=%d\nformat=%d\n\n" mtime info.Unix.st_size format_version;
                  self#regenerate_cache ch
                );
                self#load_cache in
              if data.mtime <> info.Unix.st_mtime then (
                if data.mtime <> -1.0 then
                  log_info "Modification time of %s has changed; invalidating cache" source;
                flush ()
              ) else if data.size <> info.Unix.st_size then (
                log_info "Size of %s has changed; invalidating cache" source;
                flush ()
              ) else if data.rev <> format_version then (
                log_info "Format of cache %s has changed; invalidating cache" cache_path;
                flush ()
              )

        (** The cache is being regenerated. The header has been written (to a temporary file). If you want to
         * pre-populate the cache, do it here. Otherwise, you can populate it lazily using [get ~if_missing]. *)
        method private regenerate_cache _ch = ()

        (** Look up an item in the cache.
         * @param if_missing called if given and no entries are found
         *)
        method get ?if_missing (key:string) : (string list * quick_test option) =
          self#ensure_valid;
          let quick_test_file = Some (source, UnchangedSince data.mtime) in
          match Hashtbl.find_all data.contents key, if_missing with
          | [], Some if_missing ->
              let result = if_missing key in
              self#put key result;
              (result, quick_test_file)
          | result, _ -> (result, quick_test_file)

        initializer self#load_cache
      end
  end

(** Lookup [elem]'s package in the cache. Generate the ID(s) for the cached implementations and check that one of them
    matches the [id] attribute on [elem].
    Returns [false] if the cache is out-of-date. *)
let check_cache id_prefix elem (cache:Cache.cache) =
  match ZI.get_attribute_opt "package" elem with
  | None ->
      Qdom.log_elem Support.Logging.Warning "Missing 'package' attribute" elem;
      false
  | Some package ->
      let sel_id = ZI.get_attribute "id" elem in
      let matches data =
        let installed_version, machine = Utils.split_pair U.re_tab data in
        let installed_id = Printf.sprintf "%s:%s:%s:%s" id_prefix package installed_version machine in
        (* log_warning "Want %s %s, have %s" package sel_id installed_id; *)
        sel_id = installed_id in
      List.exists matches (fst (cache#get package))

module Debian = struct
  let dpkg_db_status = "/var/lib/dpkg/status"

  type apt_cache_entry = {
    version : string;
    machine : string;
    size : Int64.t option;
  }

  let debian_distribution ?(status_file=dpkg_db_status) config =
    let apt_cache = Hashtbl.create 10 in
    let system = config.system in

    (* Populate [apt_cache] with the results. *)
    let query_apt_cache package_names =
      package_names |> Lwt_list.iter_s (fun package ->
        (* Check to see whether we could get a newer version using apt-get *)
        lwt result =
          try_lwt
            lwt out = Lwt_process.pread ~stderr:`Dev_null (U.make_command system ["apt-cache"; "show"; "--no-all-versions"; "--"; package]) in
            let machine = ref None in
            let version = ref None in
            let size = ref None in
            let stream = U.stream_of_lines out in
            begin try
              while true do
                let line = Stream.next stream |> trim in
                if U.starts_with line "Version: " then (
                  version := try_cleanup_distro_version_warn (U.string_tail line 9 |> trim) package
                ) else if U.starts_with line "Architecture: " then (
                  machine := Some (Support.System.canonical_machine (U.string_tail line 14 |> trim))
                ) else if U.starts_with line "Size: " then (
                  size := Some (Int64.of_string (U.string_tail line 6 |> trim))
                )
              done
            with Stream.Failure -> () end;
            match !version, !machine with
            | Some version, Some machine -> Lwt.return (Some {version = Versions.format_version version; machine; size = !size})
            | _ -> Lwt.return None
          with ex ->
            log_warning ~ex "'apt-cache show %s' failed" package;
            Lwt.return None in
        (* (multi-arch support? can there be multiple candidates?) *)
        Hashtbl.replace apt_cache package result;
        Lwt.return ()
      ) in

    (* Returns information about this package, or ["-"] if it's not installed. *)
    let query_dpkg package_name =
      let results = ref [] in
      U.finally_do Unix.close (Unix.openfile Support.System.dev_null [Unix.O_WRONLY] 0)
        (fun dev_null ->
          ["dpkg-query"; "-W"; "--showformat=${Version}\t${Architecture}\t${Status}\n"; "--"; package_name]
            |> U.check_output ~stderr:(`FD dev_null) system (fun ch  ->
              try
                while true do
                  let line = input_line ch in
                  match Str.bounded_split_delim U.re_tab line 3 with
                  | [] -> ()
                  | [version; debarch; status] ->
                      if U.ends_with status " installed" then (
                        let debarch =
                          try U.string_tail debarch (String.rindex debarch '-' + 1)
                          with Not_found -> debarch in
                        match try_cleanup_distro_version_warn version package_name with
                        | None -> ()
                        | Some clean_version ->
                            let r = Printf.sprintf "%s\t%s" (Versions.format_version clean_version) (Support.System.canonical_machine (trim debarch)) in
                            results := r :: !results
                      )
                  | _ -> log_warning "Can't parse dpkg output: '%s'" line
                done
              with End_of_file -> ()
            )
        );
      if !results = [] then ["-"] else !results in

    let fixup_java_main impl java_version =
      let java_arch = if impl.Feed.machine = Some "x86_64" then Some "amd64" else impl.Feed.machine in

      match java_arch with
      | None -> log_warning "BUG: Missing machine type on Java!"; None
      | Some java_arch ->
          let java_bin = Printf.sprintf "/usr/lib/jvm/java-%s-%s/jre/bin/java" java_version java_arch in
          if system#file_exists java_bin then Some java_bin
          else (
            (* Try without the arch... *)
            let java_bin = Printf.sprintf "/usr/lib/jvm/java-%s/jre/bin/java" java_version in
            if system#file_exists java_bin then Some java_bin
            else (
              log_info "Java binary not found (%s)" java_bin;
              Some "/usr/bin/java"
            )
          ) in

    object (self : #Distro.distribution)
      inherit Distro.distribution config as super
      val check_host_python = false

      val distro_name = "Debian"
      val id_prefix = "package:deb"
      val cache = new Cache.cache config "dpkg-status.cache" status_file 2 ~old_format:false

      method! is_installed elem =
        check_cache id_prefix elem cache || super#is_installed elem

      method! private get_package_impls query =
        (* Add any PackageKit candidates *)
        super#get_package_impls query;

        (* Add apt-cache candidates (there won't be any if we used PackageKit) *)
        let package_name = query.package_name in
        let entry = try Hashtbl.find apt_cache package_name with Not_found -> None in
        entry |> if_some (fun {version; machine; size = _} ->
          let version = Versions.parse_version version in
          let machine = Arch.none_if_star machine in
          self#add_package_implementation ~is_installed:false ~version ~machine ~quick_test:None ~distro_name query
        );

        (* Add installed packages by querying dpkg. *)
        let infos, quick_test = cache#get ~if_missing:query_dpkg package_name in
        if infos <> ["-"] then (
          infos |> List.iter (fun cached_info ->
            match Str.split_delim U.re_tab cached_info with
            | [version; machine] ->
                let version = Versions.parse_version version in
                let machine = Arch.none_if_star machine in
                self#add_package_implementation ~is_installed:true ~version ~machine ~quick_test ~distro_name query
            | _ ->
                log_warning "Unknown cache line format for '%s': %s" package_name cached_info
          )
        )

      method! check_for_candidates feed =
        match Distro.get_matching_package_impls self feed with
        | [] -> Lwt.return ()
        | matches ->
            lwt available = packagekit#is_available in
            if available then (
              let package_names = matches |> List.map (fun (elem, _props) -> ZI.get_attribute "package" elem) in
              packagekit#check_for_candidates package_names
            ) else (
              (* No PackageKit. Use apt-cache directly. *)
              query_apt_cache (matches |> List.map (fun (elem, _props) -> (ZI.get_attribute "package" elem)))
            )

      method! private add_package_implementation ?id ?main ?retrieval_method query ~version ~machine ~quick_test ~is_installed ~distro_name =
        let version =
          match query.package_name, version with
          | ("openjdk-6-jre" | "openjdk-7-jre"), (([major], Versions.Pre) :: (minor, mmod) :: rest) ->
            (* Debian marks all Java versions as pre-releases
               See: http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=685276 *)
            (major :: minor, mmod) :: rest
          | _ -> version in

        super#add_package_implementation ?id ?main ?retrieval_method query ~version ~machine ~quick_test ~is_installed ~distro_name

      method! private get_correct_main impl run_command =
        let id = Feed.get_attr_ex Constants.FeedAttr.id impl in
        if U.starts_with id "package:deb:openjdk-6-jre:" then
          fixup_java_main impl "6-openjdk"
        else if U.starts_with id "package:deb:openjdk-7-jre:" then
          fixup_java_main impl "7-openjdk"
        else
          super#get_correct_main impl run_command
    end
end

module RPM = struct
  let rpm_db_packages = "/var/lib/rpm/Packages"

  let rpm_distribution ?(rpm_db_packages = rpm_db_packages) config =
    let fixup_java_main impl java_version =
      (* (note: on Fedora, unlike Debian, the arch is x86_64, not amd64) *)

      match impl.Feed.machine with
      | None -> log_warning "BUG: Missing machine type on Java!"; None
      | Some java_arch ->
          let java_bin = Printf.sprintf "/usr/lib/jvm/jre-%s.%s/bin/java" java_version java_arch in
          if config.system#file_exists java_bin then Some java_bin
          else (
            (* Try without the arch... *)
            let java_bin = Printf.sprintf "/usr/lib/jvm/jre-%s/bin/java" java_version in
            if config.system#file_exists java_bin then Some java_bin
            else (
              log_info "Java binary not found (%s)" java_bin;
              Some "/usr/bin/java"
            )
          ) in

    object (self)
      inherit Distro.distribution config as super
      val check_host_python = false

      val distro_name = "RPM"
      val id_prefix = "package:rpm"
      val cache =
        object
          inherit Cache.cache config "rpm-status.cache" rpm_db_packages 2 ~old_format:true
          method! private regenerate_cache ch =
            ["rpm"; "-qa"; "--qf=%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n"]
              |> U.check_output config.system (fun from_rpm  ->
                try
                  while true do
                    let line = input_line from_rpm in
                    match Str.bounded_split_delim U.re_tab line 3 with
                    | ["gpg-pubkey"; _; _] -> ()
                    | [package; version; rpmarch] ->
                        let zi_arch = Support.System.canonical_machine (trim rpmarch) in
                        try_cleanup_distro_version_warn version package |> if_some (fun clean_version ->
                          Printf.fprintf ch "%s\t%s\t%s\n" package (Versions.format_version clean_version) zi_arch
                        )
                    | _ -> log_warning "Invalid output from 'rpm': %s" line
                  done
                with End_of_file -> ()
              )
        end

      method! private get_package_impls query =
        (* Add any PackageKit candidates *)
        super#get_package_impls query;

        (* Add installed packages by querying rpm *)
        let infos, quick_test = cache#get query.package_name in
        infos |> List.iter (fun cached_info ->
          match Str.split_delim U.re_tab cached_info with
          | [version; machine] ->
              let version = Versions.parse_version version in
              let machine = Arch.none_if_star machine in
              self#add_package_implementation ~is_installed:true ~version ~machine ~quick_test ~distro_name query
          | _ ->
              log_warning "Unknown cache line format for '%s': %s" query.package_name cached_info
        )

      method! is_installed elem =
        check_cache id_prefix elem cache || super#is_installed elem

      method! private get_correct_main impl run_command =
        (* OpenSUSE uses _, Fedora uses . *)
        let id = Feed.get_attr_ex Constants.FeedAttr.id impl in
        let starts x = U.starts_with id x in
        if starts "package:rpm:java-1.6.0-openjdk:" || starts "package:rpm:java-1_6_0-openjdk:" then
          fixup_java_main impl "1.6.0-openjdk"
        else if starts "package:rpm:java-1.7.0-openjdk:" || starts "package:rpm:java-1_7_0-openjdk:" then
          fixup_java_main impl "1.7.0-openjdk"
        else
          super#get_correct_main impl run_command

      method! private add_package_implementation ?id ?main ?retrieval_method query ~version ~machine ~quick_test ~is_installed ~distro_name =
        let version =
          (* OpenSUSE uses _, Fedora uses . *)
          let package_name = String.copy query.package_name in
          for i = 0 to String.length package_name - 1 do
            if package_name.[i] = '_' then package_name.[i] <- '.'
          done;
          match package_name with
          | "java-1.6.0-openjdk" | "java-1.7.0-openjdk"
          | "java-1.6.0-openjdk-devel" | "java-1.7.0-openjdk-devel" ->
              (* OpenSUSE uses 1.6 to mean 6 *)
              begin match version with
              | (1L :: major, mmod) :: rest -> (major, mmod) :: rest
              | _ -> version end;
          | _ -> version in

        super#add_package_implementation ?id ?main ?retrieval_method query ~version ~machine ~quick_test ~is_installed ~distro_name
    end
end

module ArchLinux = struct
  let arch_db = "/var/lib/pacman"

  let arch_distribution ?(arch_db=arch_db) config =
    let packages_dir = arch_db ^ "/local" in
    let parse_dirname entry =
      try
        let build_dash = String.rindex entry '-' in
        let version_dash = String.rindex_from entry (build_dash - 1) '-' in
        Some (String.sub entry 0 version_dash,
              U.string_tail entry (version_dash + 1))
      with Not_found -> None in

    let get_arch desc_path =
      let arch = ref None in
      desc_path |> config.system#with_open_in [Open_rdonly; Open_text] (fun ch ->
        try
          while !arch = None do
            let line = input_line ch in
            if line = "%ARCH%" then
              arch := Some (trim (input_line ch))
          done
        with End_of_file -> ()
      );
      !arch in

    let entries = ref (-1.0, StringMap.empty) in
    let get_entries () =
      let (last_read, items) = !entries in
      match config.system#stat packages_dir with
      | Some info when info.Unix.st_mtime > last_read -> (
          match config.system#readdir packages_dir with
          | Success items ->
              let add map entry =
                match parse_dirname entry with
                | Some (name, version) -> StringMap.add name version map
                | None -> map in
              let new_items = Array.fold_left add StringMap.empty items in
              entries := (info.Unix.st_mtime, new_items);
              new_items
          | Problem ex ->
              log_warning ~ex "Can't read packages dir '%s'!" packages_dir;
              items
      )
      | _ -> items in

    object (self : #Distro.distribution)
      inherit Distro.distribution config as super
      val check_host_python = false

      val distro_name = "Arch"
      val id_prefix = "package:arch"

      (* We should never get here for an installed package, because we always set quick-test-* *)
      method! is_installed _elem = false

      method! private get_package_impls query =
        (* Start with impls from PackageKit *)
        super#get_package_impls query;

        (* Check the local package database *)
        let package_name = query.package_name in
        log_debug "Looking up distribution packages for %s" package_name;
        let items = get_entries () in
        match StringMap.find package_name items with
        | None -> ()
        | Some version ->
            let entry = package_name ^ "-" ^ version in
            let desc_path = packages_dir +/ entry +/ "desc" in
            match get_arch desc_path with
            | None ->
                log_warning "No ARCH in %s" desc_path
            | Some arch ->
                let machine = Support.System.canonical_machine arch in
                match try_cleanup_distro_version_warn version package_name with
                | None -> ()
                | Some version ->
                    let machine = Arch.none_if_star machine in
                    let quick_test = Some (desc_path, Exists) in
                    self#add_package_implementation ~is_installed:true ~version ~machine ~quick_test ~distro_name query
    end
end

module Mac = struct
  let macports_db = "/opt/local/var/macports/registry/registry.db"

  (* Note: we currently don't have or need DarwinDistribution, because that uses quick-test-* attributes *)

  let macports_distribution ?(macports_db=macports_db) config slave =
    object
      inherit Distro.python_fallback_distribution slave "MacPortsDistribution" [macports_db] as super
      val check_host_python = true

      val! system_paths = ["/opt/local/bin"]

      val distro_name = "MacPorts"
      val id_prefix = "package:macports"
      val cache = new Cache.cache config "macports-status.cache" macports_db 2 ~old_format:true

      method! is_installed elem =
        check_cache id_prefix elem cache || super#is_installed elem

      method! match_name name = (name = distro_name || name = "Darwin")
    end

  let darwin_distribution _config slave =
    object
      inherit Distro.python_fallback_distribution slave "DarwinDistribution" []
      val check_host_python = true
      val distro_name = "Darwin"
      val id_prefix = "package:darwin"
    end
end

module Win = struct
  let windows_distribution config =
    let api = !Support.Windows_api.windowsAPI |? lazy (raise_safe "Failed to load Windows support module!") in

    let read_hklm_reg reader =
      let open Support.Windows_api in
      match config.system#platform.Platform.machine with
      | "x86_64" ->
          let value32 = reader KEY_WOW64_32KEY in
          let value64 = reader KEY_WOW64_64KEY in
          (value32, value64)
      | _ ->
          let value32 = reader KEY_WOW64_NONE in
          (value32, None) in

    object (self)
      inherit Distro.distribution config as super
      val check_host_python = false (* (0install's bundled Python may not be generally usable) *)

      val! system_paths = []

      val distro_name = "Windows"
      val id_prefix = "package:windows"

      method! private get_package_impls query =
        super#get_package_impls query;

        let package_name = query.package_name in
        match package_name with
        | "openjdk-6-jre" -> self#find_java "Java Runtime Environment" "1.6" "6" query
        | "openjdk-6-jdk" -> self#find_java "Java Development Kit"     "1.6" "6" query
        | "openjdk-7-jre" -> self#find_java "Java Runtime Environment" "1.7" "7" query
        | "openjdk-7-jdk" -> self#find_java "Java Development Kit"     "1.7" "7" query
        | "netfx" ->
            self#find_netfx "v2.0.50727" "2.0" query;
            self#find_netfx "v3.0"       "3.0" query;
            self#find_netfx "v3.5"       "3.5" query;
            self#find_netfx "v4\\Full"   "4.0" query;
            self#find_netfx_release "v4\\Full" 378389 "4.5" query;
            self#find_netfx "v5" "5.0" query;
        | "netfx-client" ->
            self#find_netfx "v4\\Client" "4.0" query;
            self#find_netfx_release "v4\\Client" 378389 "4.5" query;
        | _ -> ()

        (* No PackageKit support on Windows *)
      method! check_for_candidates _feed = Lwt.return ()

      method private find_netfx win_version zero_version query =
        let reg_path = "SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\" ^ win_version in
        let netfx32_install, netfx64_install = read_hklm_reg (api#read_registry_int reg_path "Install") in

        [(netfx32_install, "i486"); (netfx64_install, "x86_64")] |> List.iter (function
          | None, _ -> ()
          | Some install, machine ->
              let version = Versions.parse_version zero_version in
              self#add_package_implementation
                ~main:""      (* .NET executables do not need a runner on Windows but they need one elsewhere *)
                ~is_installed:(install = 1)
                ~version
                ~machine:(Some machine)
                ~quick_test:None
                ~distro_name
                query
        )

      method private find_netfx_release win_version release_version zero_version query =
        let reg_path = "SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\" ^ win_version in
        let netfx32_install, netfx64_install = read_hklm_reg (api#read_registry_int reg_path "Install") in
        let netfx32_release, netfx64_release = read_hklm_reg (api#read_registry_int reg_path "Release") in

        [(netfx32_install, netfx32_release, "i486"); (netfx64_install, netfx64_release, "x86_64")] |> List.iter (function
          | Some install, Some release, machine ->
              let version = Versions.parse_version zero_version in
              self#add_package_implementation
                ~main:""      (* .NET executables do not need a runner on Windows but they need one elsewhere *)
                ~is_installed:(install = 1 && release >= release_version)
                ~version
                ~machine:(Some machine)
                ~quick_test:None
                ~distro_name
                query
          | _ -> ()
        )

      method private find_java part win_version zero_version query =
        let reg_path = Printf.sprintf "SOFTWARE\\JavaSoft\\%s\\%s" part win_version in
        let java32_home, java64_home = read_hklm_reg (api#read_registry_string reg_path "JavaHome") in

        [(java32_home, "i486"); (java64_home, "x86_64")] |> List.iter (function
          | None, _ -> ()
          | Some home, machine ->
              let java_bin = home +/ "bin\\java.exe" in
              match config.system#stat java_bin with
              | None -> ()
              | Some info ->
                  let version = Versions.parse_version zero_version in
                  let quick_test = Some (java_bin, UnchangedSince info.Unix.st_mtime) in
                  self#add_package_implementation
                    ~main:java_bin
                    ~is_installed:true
                    ~version
                    ~machine:(Some machine)
                    ~quick_test
                    ~distro_name
                    query
        )
    end

  let cygwin_log = "/var/log/setup.log"

  let cygwin_distribution config slave =
    object
      inherit Distro.python_fallback_distribution slave "CygwinDistribution" ["/var/log/setup.log"] as super
      val check_host_python = false (* (0install's bundled Python may not be generally usable) *)

      val distro_name = "Cygwin"
      val id_prefix = "package:cygwin"
      val cache = new Cache.cache config "cygcheck-status.cache" cygwin_log 2 ~old_format:true

      method! is_installed elem =
        check_cache id_prefix elem cache || super#is_installed elem
    end
end

module Ports = struct
  let pkg_db = "/var/db/pkg"

  let ports_distribution ?(pkgdir=pkg_db) _config slave =
    object
      inherit Distro.python_fallback_distribution slave "PortsDistribution" [pkgdir]
      val check_host_python = true
      val id_prefix = "package:ports"
      val distro_name = "Ports"
    end
end

module Gentoo = struct
  let gentoo_distribution ?(pkgdir=Ports.pkg_db) _config slave =
    object
      inherit Distro.python_fallback_distribution slave "GentooDistribution" [pkgdir]
      val! valid_package_name = Str.regexp "^[^.-][^/]*/[^./][^/]*$"
      val check_host_python = false
      val distro_name = "Gentoo"
      val id_prefix = "package:gentoo"
    end
end

module Slackware = struct
  let slack_db = "/var/log/packages"

  let slack_distribution ?(packages_dir=slack_db) config =
    object (self)
      inherit Distro.distribution config
      val distro_name = "Slack"
      val id_prefix = "package:slack"

      method! private get_package_impls query =
        match config.system#readdir packages_dir with
        | Problem ex -> log_debug ~ex "get_package_impls"
        | Success items ->
            items |> Array.iter (fun entry ->
              match Str.bounded_split_delim U.re_dash entry 4 with
              | [name; version; arch; build] when name = query.package_name ->
                  let machine = Arch.none_if_star (Support.System.canonical_machine arch) in
                  try_cleanup_distro_version_warn (version ^ "-" ^ build) query.package_name |> if_some (fun version ->
                  self#add_package_implementation
                    ~is_installed:true
                    ~version
                    ~machine
                    ~quick_test:(Some (packages_dir +/ entry, Exists))
                    ~distro_name
                    query
                  )
              | _ -> ()
            )
    end
end

let get_host_distribution config (slave:Python.slave) : Distro.distribution =
  let exists = Sys.file_exists in

  match Sys.os_type with
  | "Unix" ->
      let is_debian =
        match config.system#stat Debian.dpkg_db_status with
        | Some info when info.Unix.st_size > 0 -> true
        | _ -> false in

      if is_debian then
        Debian.debian_distribution config
      else if exists ArchLinux.arch_db then
        ArchLinux.arch_distribution config
      else if exists RPM.rpm_db_packages then
        RPM.rpm_distribution config
      else if exists Mac.macports_db then
        Mac.macports_distribution config slave
      else if exists Ports.pkg_db then (
        if config.system#platform.Platform.os = "Linux" then
          Gentoo.gentoo_distribution config slave
        else
          Ports.ports_distribution config slave
      ) else if exists Slackware.slack_db then
        Slackware.slack_distribution config
      else if config.system#platform.Platform.os = "Darwin" then
        Mac.darwin_distribution config slave
      else
        generic_distribution slave
  | "Win32" -> Win.windows_distribution config
  | "Cygwin" -> Win.cygwin_distribution config slave
  | _ ->
      generic_distribution slave
