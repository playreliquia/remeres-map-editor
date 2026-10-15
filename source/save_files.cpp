//////////////////////////////////////////////////////////////////////
// This file is part of Remere's Map Editor
//////////////////////////////////////////////////////////////////////
// Remere's Map Editor is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Remere's Map Editor is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <http://www.gnu.org/licenses/>.
//////////////////////////////////////////////////////////////////////

// No main.h: the test target compiles this file without wxWidgets.
#include "save_files.h"
#include "utf8_path.h"

#include <filesystem>
#include <system_error>

namespace {
	// Windows refuses to delete a read-only file, and renaming a read-only original
	// leaves a read-only ~ copy, so the attribute is cleared first.
	bool removeSaveFile(const std::string &path) {
		const std::filesystem::path file = utf8Path(path);
		std::error_code ec;
		if (!std::filesystem::exists(file, ec)) {
			return !ec;
		}
		std::filesystem::permissions(file, std::filesystem::perms::owner_write, std::filesystem::perm_options::add, ec);
		return std::filesystem::remove(file, ec);
	}

	// Reports failure instead of throwing: a throw while ~ copies are on disk would
	// skip the rollback and the ~ bookkeeping.
	bool ensureBackupDirectoryExists(const std::string &directory) {
		const std::filesystem::path path = utf8Path(directory);
		std::error_code ec;
		if (std::filesystem::is_directory(path, ec)) {
			return true;
		}
		return std::filesystem::create_directory(path, ec);
	}
}

std::string moveIntoBackups(const SaveFile &file, const SaveBackups &backups) {
	if (!ensureBackupDirectoryExists(backups.directory)) {
		return "could not create " + backups.directory;
	}
	const std::filesystem::path target = utf8Path(file.target);
	const std::string stem = backups.directory + utf8String(target.stem()) + "." + backups.timestamp;
	const std::string extension = utf8String(target.extension());
	for (int attempt = 0; attempt < 1000; ++attempt) {
		const std::string dated = stem + (attempt == 0 ? std::string() : "-" + std::to_string(attempt)) + extension;
		std::error_code ec;
		if (std::filesystem::exists(utf8Path(dated), ec)) {
			continue;
		}
		if (ec) {
			return "could not check " + dated + ": " + ec.message();
		}
		std::filesystem::rename(utf8Path(file.backup), utf8Path(dated), ec);
		if (ec) {
			return "could not move " + file.backup + " to " + dated + ": " + ec.message();
		}
		return {};
	}
	return "could not find a free backup name for " + stem + extension;
}

bool moveFilesAside(std::vector<SaveFile> &files, const SaveBackups &backups, MapSaveResult &result, std::vector<std::string> &warnings) {
	for (SaveFile &file : files) {
		std::error_code ec;
		file.existed = std::filesystem::exists(utf8Path(file.target), ec);
	}
	for (SaveFile &file : files) {
		std::error_code ec;
		std::string reason;
		// A ~ left by an earlier save, such as one a menu save could not move into
		// backups/. A save that keeps backups moves it there; any other deletes it.
		if (std::filesystem::exists(utf8Path(file.backup), ec)) {
			if (backups.keep) {
				reason = moveIntoBackups(file, backups);
			} else if (removeSaveFile(file.backup)) {
				warnings.push_back("Deleted " + file.backup + ", left by an earlier save");
			} else {
				reason = "could not delete the old " + file.backup;
			}
		}

		if (reason.empty() && file.existed && std::filesystem::is_regular_file(utf8Path(file.target), ec)) {
			std::filesystem::rename(utf8Path(file.target), utf8Path(file.backup), ec);
			if (ec) {
				reason = "could not rename it to " + file.backup + ": " + ec.message();
			} else {
				file.movedAside = true;
			}
		}
		if (reason.empty()) {
			continue;
		}

		result.error = file.name + ": " + reason;
		result.failed.push_back({ file.name, reason });
		rollBackSave(files, result);
		return false;
	}
	return true;
}

void rollBackSave(const std::vector<SaveFile> &files, MapSaveResult &result) {
	for (const SaveFile &file : files) {
		std::error_code ec;
		if (file.movedAside) {
			// An unchanged sidecar's ~ copy was already renamed back by the writer.
			if (!std::filesystem::exists(utf8Path(file.backup), ec)) {
				continue;
			}
			std::filesystem::rename(utf8Path(file.backup), utf8Path(file.target), ec);
			if (ec) {
				result.failed.push_back({ file.name, "could not restore it from " + file.backup + ": " + ec.message() });
			} else {
				result.restored.push_back(file.name);
			}
		} else if (!file.existed && std::filesystem::is_regular_file(utf8Path(file.target), ec)) {
			if (removeSaveFile(file.target)) {
				result.removed.push_back(file.name);
			} else {
				result.failed.push_back({ file.name, "could not remove the file this save created" });
			}
		}
	}
}

void retireSaveBackups(const std::vector<SaveFile> &files, const SaveBackups &backups, std::vector<std::string> &warnings) {
	for (const SaveFile &file : files) {
		if (!file.movedAside) {
			continue;
		}
		if (!backups.keep) {
			if (!removeSaveFile(file.backup)) {
				warnings.push_back("Could not delete " + file.backup);
			}
			continue;
		}
		std::error_code ec;
		if (!std::filesystem::exists(utf8Path(file.backup), ec)) {
			continue;
		}
		const std::string failure = moveIntoBackups(file, backups);
		if (!failure.empty()) {
			warnings.push_back("Keeping " + file.backup + " until the next save: " + failure);
		}
	}
}
