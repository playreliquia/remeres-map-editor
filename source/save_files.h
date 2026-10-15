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

#ifndef RME_SAVE_FILES_H_
#define RME_SAVE_FILES_H_

// The file moves around Editor::saveMap: moving each file aside to its ~ copy,
// rolling back, and moving ~ copies into backups/. Only std::filesystem, so the
// tests build it without wxWidgets. Every path is UTF-8.

#include <string>
#include <vector>

struct MapSaveResult {
	struct FailedFile {
		std::string file;
		std::string error;
	};

	bool saved = false;
	std::string error;
	// File names beside the map, never paths: the sidecars a successful save wrote,
	// and on failure the files renamed back from their ~ copies and the files this
	// save created and then deleted.
	std::vector<std::string> sidecars;
	std::vector<std::string> restored;
	std::vector<std::string> removed;
	std::vector<FailedFile> failed;
};

// One file a save replaces, the map or a sidecar, and its ~ copy.
struct SaveFile {
	std::string target;
	std::string backup;
	std::string name;
	bool existed = false;
	bool movedAside = false;
};

// Where a save that keeps backups moves its ~ copies. The directory ends in a
// separator; the timestamp goes into each backup's name.
struct SaveBackups {
	bool keep = false;
	std::string directory;
	std::string timestamp;
};

// Windows refuses to delete a read-only file, and renaming a read-only original
// leaves a read-only ~ copy, so the attribute is cleared first.
bool removeSaveFile(const std::string &path);

// Reports failure instead of throwing: a throw while ~ copies are on disk would
// skip the rollback and the ~ bookkeeping.
bool ensureBackupDirectoryExists(const std::string &directory);

// Moves a ~ copy into the backups directory as <name>.<timestamp>.<ext> and
// returns why it could not, or "" on success. fs::rename replaces an existing
// file, so when a save in the same second took the name, -1, -2, ... is appended.
std::string moveIntoBackups(const SaveFile &file, const SaveBackups &backups);

// Moves every existing file to its ~ copy. A ~ left by an earlier save goes into
// backups when they are kept and is deleted otherwise. On the first file that
// cannot be moved, records it in result, rolls back the files already moved and
// returns false, so nothing is written unless every file was moved aside.
// warnings receives each earlier ~ this deleted.
bool moveFilesAside(std::vector<SaveFile> &files, const SaveBackups &backups, MapSaveResult &result, std::vector<std::string> &warnings);

// Puts every file back as it was before the save: each ~ copy this save made is
// renamed back over whatever the write left, and a file the save created is
// removed. Records each file in result.restored, removed or failed.
void rollBackSave(const std::vector<SaveFile> &files, MapSaveResult &result);

// After a successful write: moves each ~ copy this save made into backups when
// they are kept, else deletes it. A ~ that cannot be moved stays for the next
// save that keeps backups. Returns a warning for each ~ left behind.
std::vector<std::string> retireSaveBackups(const std::vector<SaveFile> &files, const SaveBackups &backups);

#endif
