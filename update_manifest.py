"""This script requires Python 3.10.0 or higher to run."""

import configparser
import fnmatch
import hashlib
import logging
import pathlib
import re
import xml.etree.ElementTree as Et
from typing import Any, Callable

alphanumeric_pattern = re.compile(r"(\d+)")


def _exclude_file(file_patterns: set[str], path: pathlib.Path) -> bool:
    """Whether to exclude a single file. Supports glob patterns (e.g., '*.scm')."""
    return any(fnmatch.fnmatch(path.name, pattern) for pattern in file_patterns)


def _exclude_directory(directory_names: set[str], path: pathlib.Path) -> bool:
    """Whether to exclude a directory. Doesn't consider any files in directories."""
    return any(
        len(path.parts) <= 1
        or all(a == b for a, b in zip(directory.split("/"), path.parts))
        for directory in directory_names
    )


def _parse_list_option(config: configparser.ConfigParser, section: str, option: str) -> set[str]:
    """Split a comma-separated option into a cleaned set of entries."""
    if not config.has_option(section, option):
        return set()
    return {
        entry
        for entry in map(str.strip, config[section][option].split(","))
        if entry
    }


def _alphanumeric(key: str) -> list[int | str]:
    """Natural sorting order for numbers, e.g. 10 follows 9."""
    return [
        int(character) if character.isdigit() else character.lower()
        for character in re.split(alphanumeric_pattern, key)
    ]


# Two hosts, chosen per part:
#
#   the payload (runtime, program, tree) is a thousand-odd files, and
#   raw.githubusercontent.com stalls at a few KB/s here and sometimes holds
#   the connection open with no data, which makes such an update impossible.
#   jsDelivr serves the same repository through a CDN and is fast.
#
#   the manifest itself must never come from a cache -- the client reads it to
#   learn where the files are, so a stale copy delays every release by the
#   CDN's TTL. It is 160 KB, which raw can deliver even when slow.
DEFAULT_BASE_URL = "https://cdn.jsdelivr.net/gh/o2bubble/path-of-building-fork@{branch}/"
MANIFEST_BASE_URL = "https://raw.githubusercontent.com/o2bubble/path-of-building-fork/{branch}/"
DEFAULT_BRANCH = "dev"


def create_manifest(
    version: str | None = None,
    replace: bool = False,
    base_url: str = DEFAULT_BASE_URL,
    manifest_base_url: str = MANIFEST_BASE_URL,
    branch: str = DEFAULT_BRANCH,
) -> None:
    """Generate new SHA1 hashes and version number for Path of Building's manifest file.

    The base URL is this fork's, not upstream's: an update must never pull
    upstream files over the localized ones.

    :param version: Three-part version number following https://semver.org/.
    :param replace: Whether to overwrite the existing manifest file.
    :param base_url: Download root, with "{branch}" where the branch goes.
    :param branch: Branch the "{branch}" placeholder resolves to at runtime.
    :return:
    """
    base_path = pathlib.Path().absolute()
    try:
        old_manifest = Et.parse(base_path / "manifest.xml")
    except FileNotFoundError:
        logging.critical(f"Manifest file not found in path '{base_path}'")
        return
    old_root = old_manifest.getroot()
    if (old_version := old_root.find("Version")) is None:
        logging.critical(f"Manifest file in {base_path} has no element 'Version'")
        return
    if (new_version := version or old_version.get("number")) is None:
        logging.critical(f"Manifest file in {base_path} has no attribute 'number'")
        return

    config = configparser.ConfigParser()
    try:
        config.read("manifest.cfg")
    except FileNotFoundError:
        logging.critical(f"Manifest configuration file not found in path '{base_path}'")
        return

    parts: list[dict[str, str]] = []
    for part in config.sections():
        # "default" is where the client fetches manifest.xml and changelog.txt
        # from; the rest carry the update payload. See MANIFEST_BASE_URL.
        host = manifest_base_url if part == "default" else base_url
        url = host + config[part]["path"]
        url_with_trailing_slash = url if url.endswith("/") else url + "/"
        attributes = (
            {"part": part, "platform": "win32", "url": url_with_trailing_slash}
            if part == "runtime"
            else {"part": part, "url": url_with_trailing_slash}
        )
        parts.append(attributes)

    files: list[dict[str, str]] = []
    for section in config.sections():
        include_files = _parse_list_option(config, section, "include-files")
        include_dirs = _parse_list_option(config, section, "include-directories")
        exclude_files = _parse_list_option(config, section, "exclude-files")
        exclude_dirs = _parse_list_option(config, section, "exclude-directories")
        source = pathlib.Path(config[section]["path"])
        for path in source.glob("**/*.*"):
            if include_files and not _exclude_file(include_files, path):
                continue
            if include_dirs and not _exclude_directory(include_dirs, path):
                continue
            if exclude_files and _exclude_file(exclude_files, path):
                continue
            if exclude_dirs and _exclude_directory(exclude_dirs, path):
                continue
            data = path.read_bytes()
            # Normalize line endings for non-binary files in case they were accidentally mixed
            if b"\0" not in data:
                data = re.sub(rb"\r\n?|\n", b"\r\n", data)
            sha1 = hashlib.sha1(data).hexdigest()
            name = path.relative_to(config[section]["path"]).as_posix()
            attributes = (
                {"name": name, "part": section, "platform": "win32", "sha1": sha1}
                if path.suffix in [".dll", ".exe"]
                else {"name": name, "part": section, "sha1": sha1}
            )
            files.append(attributes)

    files.sort(key=lambda attr: (attr["part"], _alphanumeric(attr["name"])))

    root = Et.Element("PoBVersion")
    # The branch has to be recorded or the runtime refuses to resolve {branch}
    # in the Source URLs ("invalid local manifest").
    #
    # The platform is what the updater uses to pick a source for the runtime
    # part: it looks up sources[platform], and that part is the only one
    # declared per platform. Without it the lookup finds nothing, the source
    # is nil, and the update thread dies on the first runtime file it has to
    # fetch -- which is what happened to a release whose manifest omitted it.
    Et.SubElement(root, "Version", number=new_version, platform="win32", branch=branch)
    for attributes in parts:
        Et.SubElement(root, "Source", attributes)
    for attributes in files:
        Et.SubElement(root, "File", attributes)
    file_name = "manifest.xml" if replace else "manifest-updated.xml"
    tree = Et.ElementTree(root)
    Et.indent(tree, "\t")
    tree.write(base_path / file_name, encoding="UTF-8", xml_declaration=True)
    if version is not None:
        logging.info(f"Updated to version {version}")


def cli() -> None:
    """CLI for conveniently updating Path of Building's manifest file."""
    import argparse

    parser = argparse.ArgumentParser(
        usage="%(prog)s [options]",
        description="Update Path of Building's manifest file for a new release.",
        allow_abbrev=False,
    )
    parser.add_argument("--version", action="version", version="2.0.0")
    logging_level = parser.add_mutually_exclusive_group()
    logging_level.add_argument(
        "-v", "--verbose", action="store_true", help="Print more logging information"
    )
    logging_level.add_argument(
        "-q", "--quiet", action="store_true", help="Print no logging information"
    )
    parser.add_argument("--in-place", action="store_true", help="Replace original file")
    parser.add_argument(
        "--set-version",
        action="store",
        help="Set manifest version number",
        metavar="SEMVER",
    )
    parser.add_argument(
        "--base-url",
        action="store",
        help=f"Payload download root, with {{branch}} placeholder (default: {DEFAULT_BASE_URL})",
        default=DEFAULT_BASE_URL,
    )
    parser.add_argument(
        "--manifest-base-url",
        action="store",
        help=f"Where the client fetches manifest.xml from (default: {MANIFEST_BASE_URL})",
        default=MANIFEST_BASE_URL,
    )
    parser.add_argument(
        "--branch",
        action="store",
        help=f"Branch the {{branch}} placeholder resolves to (default: {DEFAULT_BRANCH})",
        default=DEFAULT_BRANCH,
    )
    args = parser.parse_args()
    if args.verbose:
        logging.basicConfig(level=logging.INFO)
    elif args.quiet:
        logging.basicConfig(level=logging.CRITICAL + 1)
    create_manifest(args.set_version or None, args.in_place, args.base_url,
                    args.manifest_base_url, args.branch)


if __name__ == "__main__":
    cli()
