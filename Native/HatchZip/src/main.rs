use anyhow::{Context, Result, bail};
use hatchzip_core::archive::storage::Reads;
use hatchzip_core::{
    engine::{Job, Outcome, Progress, Run},
    journal::{Journal, Paths},
    session,
};
use serde::{Deserialize, Serialize};
use std::os::unix::{
    ffi::OsStrExt,
    fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
};
use std::{
    fs::{self, File, OpenOptions},
    io::{self, BufRead, Write},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};

use zeroize::Zeroize;

const KEEP_FREE: u64 = 64 * 1024 * 1024;
static STOP: AtomicBool = AtomicBool::new(false);

#[derive(Deserialize)]
struct Request {
    action: String,
    directory: PathBuf,
    input: Option<PathBuf>,
    password: Option<String>,
}

impl Drop for Request {
    fn drop(&mut self) {
        if let Some(password) = self.password.as_mut() {
            password.zeroize();
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
struct Identity {
    path: PathBuf,
    device: u64,
    inode: u64,
}

#[derive(Clone, Serialize, Deserialize)]
struct Manifest {
    version: u32,
    input: PathBuf,
    output: PathBuf,
    output_device: u64,
    output_inode: u64,
    parts: Vec<Identity>,
    quarantine: Option<Vec<u8>>,
    state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    probe: Option<Identity>,
}

fn emit(value: serde_json::Value) {
    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    if serde_json::to_writer(&mut stdout, &value).is_err() || stdout.write_all(b"\n").is_err() {
        STOP.store(true, Ordering::Relaxed);
    }
}

fn private_directory(path: &Path, create: bool) -> Result<()> {
    if create {
        fs::create_dir(path)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_dir() || meta.uid() != unsafe { libc::getuid() } || meta.mode() & 0o077 != 0 {
        bail!("The recovery directory is not private");
    }
    Ok(())
}

fn save_manifest(directory: &Path, manifest: &Manifest) -> Result<()> {
    let pending = directory.join("manifest.pending");
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&pending)?;
    serde_json::to_writer(&mut file, manifest)?;
    file.sync_all()?;
    fs::rename(pending, directory.join("manifest.json"))?;
    File::open(directory)?.sync_all()?;
    Ok(())
}

fn validate_input(path: &Path) -> Result<Identity> {
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_file() || meta.nlink() != 1 {
        bail!("Only regular files without hard links can be extracted in place");
    }
    let name = std::ffi::CString::new(path.as_os_str().as_bytes())?;
    let mut stat = std::mem::MaybeUninit::<libc::statfs>::uninit();
    if unsafe { libc::statfs(name.as_ptr(), stat.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error().into());
    }
    let stat = unsafe { stat.assume_init() };
    if stat.f_flags & libc::MNT_LOCAL as u32 == 0 {
        bail!("Network volumes cannot be extracted in place");
    }
    if path.components().any(|c| {
        matches!(
            c.as_os_str().to_str(),
            Some("CloudStorage" | "Mobile Documents")
        )
    }) {
        bail!("File provider locations cannot be extracted in place");
    }
    Ok(Identity {
        path: path.to_path_buf(),
        device: meta.dev(),
        inode: meta.ino(),
    })
}

fn quarantine(path: &Path) -> Result<Option<Vec<u8>>> {
    let name = std::ffi::CString::new(path.as_os_str().as_bytes())?;
    let attribute = c"com.apple.quarantine";
    let size = unsafe {
        libc::getxattr(
            name.as_ptr(),
            attribute.as_ptr(),
            std::ptr::null_mut(),
            0,
            0,
            libc::XATTR_NOFOLLOW,
        )
    };
    if size < 0 {
        let error = io::Error::last_os_error();
        if matches!(error.raw_os_error(), Some(libc::ENOATTR | libc::ENOTSUP)) {
            return Ok(None);
        }
        return Err(error.into());
    }
    let mut bytes = vec![0u8; size as usize];
    if unsafe {
        libc::getxattr(
            name.as_ptr(),
            attribute.as_ptr(),
            bytes.as_mut_ptr().cast(),
            bytes.len(),
            0,
            libc::XATTR_NOFOLLOW,
        )
    } != size
    {
        return Err(io::Error::last_os_error().into());
    }
    Ok(Some(bytes))
}

fn apply_quarantine(path: &Path, bytes: &Option<Vec<u8>>) -> Result<()> {
    let Some(bytes) = bytes else {
        return Ok(());
    };
    let meta = fs::symlink_metadata(path)?;
    if quarantine(path)?.as_ref() != Some(bytes) {
        let name = std::ffi::CString::new(path.as_os_str().as_bytes())?;
        let write = || {
            if unsafe {
                libc::setxattr(
                    name.as_ptr(),
                    c"com.apple.quarantine".as_ptr(),
                    bytes.as_ptr().cast(),
                    bytes.len(),
                    0,
                    libc::XATTR_NOFOLLOW,
                )
            } == 0
            {
                Ok(())
            } else {
                Err(io::Error::last_os_error())
            }
        };
        match write() {
            Ok(()) => {}
            Err(error) if error.raw_os_error() == Some(libc::EACCES) && !meta.is_symlink() => {
                fs::set_permissions(path, fs::Permissions::from_mode(meta.mode() | 0o200))?;
                let written = write();
                fs::set_permissions(path, meta.permissions())?;
                written?;
            }
            Err(error) => return Err(error.into()),
        }
        let sync_path = if meta.is_symlink() {
            path.parent().context("Missing output parent")?
        } else {
            path
        };
        File::open(sync_path)?.sync_all()?;
    }
    if meta.is_dir() {
        for entry in fs::read_dir(path)? {
            apply_quarantine(&entry?.path(), &Some(bytes.clone()))?;
        }
    }
    Ok(())
}

fn check_output(manifest: &Manifest) -> Result<()> {
    let meta = fs::symlink_metadata(&manifest.output)?;
    if !meta.is_dir() || meta.dev() != manifest.output_device || meta.ino() != manifest.output_inode
    {
        bail!("The extraction output directory has changed");
    }
    Ok(())
}

fn paths(directory: &Path, primary: &Path) -> Paths {
    Paths {
        archive: primary.to_path_buf(),
        journal: directory.join("journal.json"),
        tail: directory.join("tail"),
    }
}

fn archive_stem(primary: &Path) -> Result<String> {
    let name = primary
        .file_name()
        .context("The archive has no filename")?
        .to_string_lossy();
    let mut stem = name.to_string();
    if let Some((base, suffix)) = stem.rsplit_once('.') {
        if suffix.len() >= 3 && suffix.bytes().all(|byte| byte.is_ascii_digit()) {
            stem = base.to_string();
        }
    }
    let lower = stem.to_ascii_lowercase();
    for suffix in [".tar.gz", ".tgz", ".zip", ".7z", ".tar"] {
        if lower.ends_with(suffix) {
            stem.truncate(stem.len() - suffix.len());
            break;
        }
    }
    if stem.is_empty() {
        bail!("The archive has no output name");
    }
    Ok(stem)
}

fn discard_unstarted(directory: &Path) -> Result<()> {
    let manifest_path = directory.join("manifest.json");
    if manifest_path.exists() {
        let manifest: Manifest = serde_json::from_reader(File::open(&manifest_path)?)?;
        if manifest.state != "ready" || directory.join("journal.json").exists() {
            return Ok(());
        }
        check_output(&manifest)?;
        fs::remove_dir(&manifest.output)?;
        fs::remove_file(manifest_path)?;
    }
    fs::remove_dir(directory)?;
    Ok(())
}

fn exclusive_output(primary: &Path) -> Result<PathBuf> {
    let parent = primary
        .parent()
        .context("The archive has no parent directory")?;
    let stem = archive_stem(primary)?;
    for suffix in 0..10000 {
        let name = if suffix == 0 {
            format!("{stem} extracted")
        } else {
            format!("{stem} extracted {suffix}")
        };
        let output = parent.join(name);
        match fs::create_dir(&output) {
            Ok(()) => {
                fs::set_permissions(&output, fs::Permissions::from_mode(0o700))?;
                return Ok(output);
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }
    bail!("No available extraction output name")
}

fn prepare(request: &Request) -> Result<Manifest> {
    let selected = request.input.as_ref().context("Missing archive")?;
    let (primary, _) = session::locate(selected)?;
    validate_input(&primary)?;
    let job = Job::open(
        &primary,
        false,
        request.password.as_deref(),
        Arc::new(Reads::default()),
    )?;
    let parts = job
        .storage
        .parts()
        .iter()
        .map(|p| validate_input(&p.path))
        .collect::<Result<Vec<_>>>()?;
    let limit = job.storage.original_len().saturating_mul(1000).max(1 << 30);
    if job.remaining_size() > limit {
        bail!("The archive exceeds the expansion limit");
    }
    if let Some(reason) = job.in_place_refusal() {
        bail!("{reason}");
    }
    job.check_password()?;
    session::check_sfv(&job.storage, &|| STOP.load(Ordering::Relaxed))?;
    let mut quarantine_value = None;
    for part in &parts {
        let value = quarantine(&part.path)?;
        if quarantine_value.is_none() {
            quarantine_value = value;
        }
    }
    let quarantine = quarantine_value;
    let output = exclusive_output(&primary)?;
    let metadata = fs::symlink_metadata(&output)?;
    let manifest = Manifest {
        version: 1,
        input: primary,
        output,
        output_device: metadata.dev(),
        output_inode: metadata.ino(),
        parts,
        quarantine,
        state: "ready".into(),
        probe: None,
    };
    save_manifest(&request.directory, &manifest)?;
    Ok(manifest)
}

fn check_path_collisions(job: &Job, manifest: &mut Manifest, directory: &Path) -> Result<()> {
    use hatchzip_core::archive::Kind;
    use std::collections::HashMap;

    if let Some(probe) = &manifest.probe {
        if probe.path != manifest.output.join(".macease-path-check") {
            bail!("The archive path-check directory is outside its output");
        }
        let meta = fs::symlink_metadata(&probe.path)?;
        if !meta.is_dir() || meta.dev() != probe.device || meta.ino() != probe.inode {
            bail!("The archive path-check directory has changed");
        }
        fs::remove_dir_all(&probe.path)?;
        manifest.probe = None;
        save_manifest(directory, manifest)?;
    }
    let root = manifest.output.join(".macease-path-check");
    fs::create_dir(&root)?;
    let metadata = fs::symlink_metadata(&root)?;
    manifest.probe = Some(Identity {
        path: root.clone(),
        device: metadata.dev(),
        inode: metadata.ino(),
    });
    save_manifest(directory, manifest)?;
    let checked = (|| -> Result<()> {
        let mut paths: HashMap<PathBuf, bool> = HashMap::new();
        for entry in job.units.iter().flat_map(|unit| &unit.items) {
            let components: Vec<_> = entry.path.components().collect();
            let mut relative = PathBuf::new();
            for (index, component) in components.iter().enumerate() {
                relative.push(component);
                let is_directory = index + 1 < components.len() || entry.kind == Kind::Dir;
                if let Some(previous) = paths.get(&relative) {
                    if *previous != is_directory {
                        bail!(
                            "Archive file and directory paths collide: {}",
                            relative.display()
                        );
                    }
                    continue;
                }
                let candidate = root.join(&relative);
                let created = if is_directory {
                    fs::create_dir(&candidate)
                } else {
                    OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .mode(0o600)
                        .open(&candidate)
                        .map(drop)
                };
                if let Err(error) = created {
                    if error.kind() == io::ErrorKind::AlreadyExists {
                        bail!(
                            "Archive paths collide on this volume: {}",
                            relative.display()
                        );
                    }
                    return Err(error.into());
                }
                paths.insert(relative.clone(), is_directory);
            }
        }
        Ok(())
    })();
    fs::remove_dir_all(&root).context("removing the owned archive path-check directory")?;
    manifest.probe = None;
    save_manifest(directory, manifest)?;
    checked
}

fn execute(request: Request) -> Result<()> {
    private_directory(&request.directory, request.action == "start")?;
    let mut manifest: Manifest = if request.action == "start" {
        prepare(&request)?
    } else {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(request.directory.join("manifest.json"))?;
        serde_json::from_reader(file)?
    };
    if manifest.version != 1 {
        bail!("Unsupported extraction session version");
    }
    check_output(&manifest)?;
    let paths = paths(&request.directory, &manifest.input);
    if manifest.state == "finished" {
        emit(serde_json::json!({"event":"finished","output":manifest.output}));
        return Ok(());
    }
    let reads = Arc::new(Reads::default());
    let state = if paths.exists() {
        let (journal, _) = Journal::load(&paths)?;
        if journal.output != manifest.output
            || journal.keep
            || journal.replace.is_some()
            || journal.parts.len() != manifest.parts.len()
            || journal
                .parts
                .iter()
                .zip(&manifest.parts)
                .any(|((path, _), part)| path != &part.path)
        {
            bail!("The recovery journal does not match this extraction session");
        }
        for part in &manifest.parts {
            if part.path.exists() {
                let current = validate_input(&part.path)?;
                if current.device != part.device || current.inode != part.inode {
                    bail!("An archive volume has changed");
                }
            }
        }
        session::open(
            &manifest.input,
            &paths,
            Some(manifest.output.clone()),
            true,
            request.password.as_deref(),
            &reads,
        )?
    } else {
        if manifest.state != "ready" {
            if manifest.state == "finishing" && !manifest.input.exists() {
                apply_quarantine(&manifest.output, &manifest.quarantine)?;
                manifest.state = "finished".into();
                save_manifest(&request.directory, &manifest)?;
                emit(serde_json::json!({"event":"finished","output":manifest.output}));
                return Ok(());
            }
            bail!("The extraction recovery journal is missing");
        }
        for part in &manifest.parts {
            let current = validate_input(&part.path)?;
            if current.device != part.device || current.inode != part.inode {
                bail!("An archive volume has changed");
            }
        }
        session::open(
            &manifest.input,
            &paths,
            Some(manifest.output.clone()),
            true,
            request.password.as_deref(),
            &reads,
        )?
    };
    let (job, journal) = match state {
        session::State::Fresh(job, output) => {
            let plan = session::plan(&job, &output, false, KEEP_FREE, false)?;
            if !plan.fits || !plan.reclaims {
                bail!("Insufficient local disk space for in-place extraction");
            }
            if STOP.load(Ordering::Relaxed) {
                emit(serde_json::json!({"event":"paused","output":manifest.output}));
                return Ok(());
            }
            check_path_collisions(&job, &mut manifest, &request.directory)?;
            emit(serde_json::json!({"event":"verifying"}));
            job.verify(&|_| {})?;
            if STOP.load(Ordering::Relaxed) {
                emit(serde_json::json!({"event":"paused","output":manifest.output}));
                return Ok(());
            }
            let journal = session::begin(&job, &paths, output, false, None)?;
            (job, journal)
        }
        session::State::Resume(job, journal) => {
            job.check_password()?;
            let plan = session::plan(&job, &journal.output, true, KEEP_FREE, false)?;
            if !plan.fits {
                bail!("Insufficient disk space to resume extraction");
            }
            session::clear_uncommitted(&job, &journal.output)?;
            (job, journal)
        }
        session::State::Orphan(journal) => {
            if manifest.state != "finishing" {
                bail!("The remaining archive is missing. Put it back before resuming extraction");
            }
            hatchzip_core::engine::finish_orphaned(&journal, &paths)?;
            apply_quarantine(&manifest.output, &manifest.quarantine)?;
            manifest.state = "finished".into();
            save_manifest(&request.directory, &manifest)?;
            emit(serde_json::json!({"event":"finished","output":manifest.output}));
            return Ok(());
        }
    };
    manifest.state = "running".into();
    save_manifest(&request.directory, &manifest)?;
    let total = journal.total_size.max(1);
    let written = AtomicU64::new(total.saturating_sub(job.remaining_size()));
    let quarantine = manifest.quarantine.clone();
    let mut finishing_manifest = manifest.clone();
    finishing_manifest.state = "finishing".into();
    let finishing_directory = request.directory.clone();
    let outcome = Run { job, journal, paths, stop: &STOP, keep_free: KEEP_FREE, progress: Progress {
        before_checkpoint: Box::new(move |output| apply_quarantine(output, &quarantine)),
        before_finish: Box::new(move |_| save_manifest(&finishing_directory, &finishing_manifest)),
        on_bytes: Box::new(move |count| { let value = written.fetch_add(count, Ordering::Relaxed).saturating_add(count); emit(serde_json::json!({"event":"progress","fraction":(value as f64 / total as f64).min(1.0)})); }),
        on_commit: Box::new(|_| {}),
    }}.execute()?;
    manifest.state = match outcome {
        Outcome::Finished => "finished",
        Outcome::Paused => "paused",
    }
    .into();
    save_manifest(&request.directory, &manifest)?;
    emit(serde_json::json!({"event":manifest.state,"output":manifest.output}));
    Ok(())
}

fn main() {
    let stdin = io::stdin();
    let mut line = String::new();
    let result: Result<Request> = stdin
        .read_line(&mut line)
        .map_err(Into::into)
        .and_then(|_| serde_json::from_str::<Request>(&line).map_err(Into::into));
    line.zeroize();
    let request = match result {
        Ok(request) => request,
        Err(error) => {
            emit(serde_json::json!({"event":"error","message":format!("{error:#}")}));
            std::process::exit(1);
        }
    };
    std::thread::spawn(|| {
        for _ in io::stdin().lock().lines() {
            STOP.store(true, Ordering::Relaxed);
        }
        STOP.store(true, Ordering::Relaxed);
    });
    let directory = request.directory.clone();
    let fresh = request.action == "start";
    if let Err(error) = execute(request) {
        if fresh && directory.exists() {
            if let Err(cleanup) = discard_unstarted(&directory) {
                emit(
                    serde_json::json!({"event":"error","message":format!("{error:#}; preflight cleanup failed: {cleanup:#}")}),
                );
                std::process::exit(1);
            }
        }
        let event = if error.is::<hatchzip_core::archive::PasswordNeeded>() {
            "passwordRequired"
        } else if error.is::<hatchzip_core::archive::WrongPassword>() {
            "wrongPassword"
        } else {
            "error"
        };
        emit(serde_json::json!({"event":event,"message":format!("{error:#}")}));
        std::process::exit(1);
    }
}
