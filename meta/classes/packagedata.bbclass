python read_subpackage_metadata () {
    import oe.packagedata

    vars = {
        "PN" : d.getVar('PN'), 
        "PE" : d.getVar('PE'), 
        "PV" : d.getVar('PV'),
        "PR" : d.getVar('PR'),
    }

    data = oe.packagedata.read_pkgdata(vars["PN"], d)

    for key in data.keys():
        d.setVar(key, data[key])

    for pkg in d.getVar('PACKAGES').split():
        sdata = oe.packagedata.read_subpkgdata(pkg, d)
        for key in sdata.keys():
            if key in vars:
                if sdata[key] != vars[key]:
                    if key == "PN":
                        bb.fatal("Recipe %s is trying to create package %s which was already written by recipe %s. This will cause corruption, please resolve this and only provide the package from one recipe or the other or only build one of the recipes." % (vars[key], pkg, sdata[key]))
                    bb.fatal("Recipe %s is trying to change %s from '%s' to '%s'. This will cause do_package_write_* failures since the incorrect data will be used and they will be unable to find the right workdir." % (vars["PN"], key, vars[key], sdata[key]))
                continue
            #
            # If we set unsuffixed variables here there is a chance they could clobber override versions
            # of that variable, e.g. DESCRIPTION could clobber DESCRIPTION:<pkgname>
            # We therefore don't clobber for the unsuffixed variable versions
            #
            if key.endswith(":" + pkg):
                d.setVar(key, sdata[key])
            else:
                d.setVar(key, sdata[key], parsing=True)
}

python packagedata_validate_setscene () {
    import os
    import oe.packagedata

    pn = d.getVar("PN")
    current = {
        "PN": pn,
        "PE": d.getVar("PE"),
        "PV": d.getVar("PV"),
        "PR": d.getVar("PR"),
    }
    pkgdata_dir = d.getVar("PACKAGEDATA_VALIDATE_DIR") or d.getVar("PKGDATA_DIR")
    recipe_data = oe.packagedata.read_pkgdatafile(
        os.path.join(pkgdata_dir, pn)
    )

    packages = set((d.getVar("PACKAGES") or "").split())
    packages.update((recipe_data.get("PACKAGES") or "").split())
    subdata = {}
    for pkg in packages:
        subdata[pkg] = oe.packagedata.read_pkgdatafile(
            os.path.join(pkgdata_dir, "runtime", pkg)
        )
    mismatch = None

    for key in current:
        restored = recipe_data.get(key)
        if restored is not None and restored != current[key]:
            mismatch = (key, current[key], restored)
            break

    if mismatch is None:
        for pkg in packages:
            for key in current:
                restored = subdata[pkg].get(key)
                if restored is not None and restored != current[key]:
                    mismatch = (key, current[key], restored)
                    break
            if mismatch is not None:
                break

    if mismatch is None:
        return

    key, expected, restored = mismatch
    for pkg in packages:
        owner = subdata[pkg].get("PN")
        if owner is not None and owner != pn:
            bb.fatal(
                "Recipe %s cannot purge package %s owned by recipe %s; "
                "resolve the package ownership conflict." % (pn, pkg, owner)
            )

    log_path = d.expand("${TMPDIR}/log/hashequivalence-debug.log")
    try:
        bb.utils.mkdirhier(os.path.dirname(log_path))
        with open(log_path, "a") as log:
            log.write(
                "%s task=%s mismatch=%s current=%r restored=%r action=purge\n"
                % (
                    pn,
                    d.getVar("BB_CURRENTTASK") or "unknown",
                    key,
                    expected,
                    restored,
                )
            )
    except OSError as e:
        bb.warn("%s: unable to write packagedata validation log %s: %s"
                % (pn, log_path, e))

    paths = [os.path.join(pkgdata_dir, pn)]
    for pkg in packages:
        paths.extend([
            os.path.join(pkgdata_dir, "runtime", pkg),
            os.path.join(pkgdata_dir, "runtime", pkg + ".packaged"),
            os.path.join(pkgdata_dir, "extended", pkg + ".json.zstd"),
        ])

    runtime_dir = os.path.join(pkgdata_dir, "runtime")
    for root in ("runtime-rprovides", "runtime-reverse"):
        provider_dir = os.path.join(pkgdata_dir, root)
        if not os.path.isdir(provider_dir):
            continue
        for directory, _, filenames in os.walk(provider_dir):
            for filename in filenames:
                path = os.path.join(directory, filename)
                if not os.path.islink(path):
                    continue
                target = os.path.realpath(path)
                if target.startswith(runtime_dir + os.sep):
                    if os.path.basename(target) in packages:
                        paths.append(path)

    for path in paths:
        if os.path.lexists(path):
            if os.path.isdir(path) and not os.path.islink(path):
                bb.fatal("Recipe %s cannot purge unexpected directory %s"
                         % (pn, path))
            os.unlink(path)

    bb.warn(
        "%s: rejecting stale packagedata restored from sstate: "
        "%s current='%s' restored='%s'; rerunning do_packagedata"
        % (pn, key, expected, restored)
    )
    d.setVar("PACKAGEDATA_STALE", "1")
}
