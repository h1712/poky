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
    recipe_data = oe.packagedata.read_pkgdata(pn, d)
    if not recipe_data:
        return

    packages = set((d.getVar("PACKAGES") or "").split())
    packages.update((recipe_data.get("PACKAGES") or "").split())
    mismatch = None

    for key in current:
        restored = recipe_data.get(key)
        if restored is not None and restored != current[key]:
            mismatch = (key, current[key], restored)
            break

    if mismatch is None:
        for pkg in packages:
            subdata = oe.packagedata.read_subpkgdata(pkg, d)
            for key in current:
                restored = subdata.get(key)
                if restored is not None and restored != current[key]:
                    mismatch = (key, current[key], restored)
                    break
            if mismatch is not None:
                break

    if mismatch is None:
        return

    key, expected, restored = mismatch
    pkgdata_dir = d.getVar("PKGDATA_DIR")
    paths = [os.path.join(pkgdata_dir, pn)]
    for pkg in packages:
        paths.extend([
            os.path.join(pkgdata_dir, "runtime", pkg),
            os.path.join(pkgdata_dir, "runtime", pkg + ".packaged"),
            os.path.join(pkgdata_dir, "runtime-reverse", pkg),
            os.path.join(pkgdata_dir, "extended", pkg + ".json.zstd"),
        ])

    runtime_dir = os.path.join(pkgdata_dir, "runtime")
    for root in ("runtime-rprovides",):
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
            os.unlink(path)

    bb.warn(
        "%s: rejecting stale packagedata restored from sstate: "
        "%s current='%s' restored='%s'; rerunning do_packagedata"
        % (pn, key, expected, restored)
    )
    raise bb.BBHandledException(
        "%s: stale packagedata restored from sstate" % pn
    )
