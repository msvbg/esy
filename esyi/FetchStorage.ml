module String = Astring.String

module Dist = struct
  type t = {
    source : Source.t;
    sourceInStorage : SourceStorage.source;
    pkg : Solution.Package.t;
  }

  let id dist = Solution.Package.id dist.pkg
  let source dist = dist.source
  let pp fmt dist =
    Fmt.pf fmt "%s@%a" dist.pkg.name Version.pp dist.pkg.version
end

let fetch ~(cfg : Config.t) (pkg : Solution.Package.t) =
  let open RunAsync.Syntax in

  let rec fetch' errs sources =
    match sources with
    | source::rest ->
      begin match%bind SourceStorage.fetch ~cfg source with
      | Ok sourceInStorage -> return {Dist. pkg; source; sourceInStorage;}
      | Error err -> fetch' ((source, err)::errs) rest
      end
    | [] ->
      Logs_lwt.err (fun m ->
        let ppErr fmt (source, err) =
          Fmt.pf fmt
            "source: %a@\nerror: %a"
            Source.pp source
            Run.ppError err
        in
        m "unable to fetch %a:@[<v 2>@\n%a@]"
          Solution.Package.pp pkg
          Fmt.(list ~sep:(unit "@\n") ppErr) errs
      );%lwt
      error "installation error"
  in

  let sources =
    let main, mirrors = pkg.source in
    main::mirrors
  in

  fetch' [] sources

let install ~cfg ~path dist =
  let open RunAsync.Syntax in
  let {Dist. source; pkg; sourceInStorage;} = dist in

  let finishInstall path =

    let%bind () =
      let f file =
        Package.File.writeToDir ~destinationDir:path file
      in
      List.map ~f pkg.files |> RunAsync.List.waitAll
    in

    return ()
  in

  let%bind () = Fs.createDir path in

  (*
   * @andreypopp: We place _esylink before unpacking tarball, but that's just
   * because we get failures on Windows due to permission errors (reproducible
   * on AppVeyor).
   *
   * I'd prefer to place _esylink after unpacking tarball to prevent tarball
   * contents overriding _esylink accidentially but probability of such event
   * is low enough so I proceeded with the current order.
   *)
  let%bind () =
    EsyLinkFile.toDir
      EsyLinkFile.{source; overrides = pkg.overrides; opam = pkg.opam}
      path
  in

  let%bind () =
    match source with
    | Source.LocalPathLink _ ->
      return ()
    | Source.NoSource ->
      let%bind () = finishInstall path in
      return ()
    | _ ->
      let%bind () = SourceStorage.unpack ~cfg ~dst:path sourceInStorage in
      let%bind () = finishInstall path in
      return ()
  in

  return ()

let path ~cfg dist =
  let id =
    Source.show dist.Dist.source
    |> Digest.string
    |> Digest.to_hex
  in
  Path.(cfg.Config.cacheSourcesPath // v id)

let unpack ~cfg dist =
  (** TODO: need to sync here so no two same tasks are running at the same time *)
  let open RunAsync.Syntax in
  let path = path ~cfg dist in
  if%bind Fs.exists path
  then return path
  else
    let tempPath = Path.(path |> addExt ".tmp") in
    let%bind () = Fs.rmPath tempPath in
    let%bind () = install ~cfg ~path:tempPath dist in
    let%bind () = Fs.rename ~src:tempPath path in
    return path
