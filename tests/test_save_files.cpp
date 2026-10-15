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

#include "save_files.h"
#include "utf8_path.h"

#include <catch2/catch_test_macros.hpp>

#include <filesystem>
#include <fstream>
#include <random>
#include <sstream>
#include <string>
#include <vector>

namespace {
	namespace fs = std::filesystem;

	const std::string timestamp = "2026-10-15-9-5-7";

	// A fresh directory under the system temp directory, removed with its contents.
	class TempDirectory {
	public:
		TempDirectory() :
			root(fs::temp_directory_path() / ("rme-tests-" + std::to_string(std::random_device {}()))) {
			fs::create_directories(root);
		}

		~TempDirectory() {
			std::error_code ec;
			fs::remove_all(root, ec);
		}

		TempDirectory(const TempDirectory &) = delete;
		TempDirectory &operator=(const TempDirectory &) = delete;

		std::string path(const std::string &name) const {
			return utf8String(root / utf8Path(name));
		}

		SaveFile saveFile(const std::string &name) const {
			return { path(name), path(name) + "~", name };
		}

		SaveBackups backups(bool keep) const {
			return { keep, path("backups") + "/", timestamp };
		}

	private:
		fs::path root;
	};

	void writeFile(const std::string &path, const std::string &contents) {
		std::ofstream file(utf8Path(path), std::ios::binary | std::ios::trunc);
		file << contents;
	}

	std::string readFile(const std::string &path) {
		std::ifstream file(utf8Path(path), std::ios::binary);
		std::ostringstream contents;
		contents << file.rdbuf();
		return contents.str();
	}

	bool exists(const std::string &path) {
		return fs::exists(utf8Path(path));
	}
}

TEST_CASE("test_moveFilesAside_existingFiles_renamesEachToItsBackup") {
	TempDirectory directory;
	writeFile(directory.path("map.otbm"), "map");
	writeFile(directory.path("map-house.xml"), "houses");
	std::vector<SaveFile> files { directory.saveFile("map.otbm"), directory.saveFile("map-house.xml") };
	MapSaveResult result;
	std::vector<std::string> warnings;

	REQUIRE(moveFilesAside(files, directory.backups(false), result, warnings));

	CHECK(files[0].movedAside);
	CHECK(files[1].movedAside);
	CHECK_FALSE(exists(directory.path("map.otbm")));
	CHECK_FALSE(exists(directory.path("map-house.xml")));
	CHECK(readFile(directory.path("map.otbm~")) == "map");
	CHECK(readFile(directory.path("map-house.xml~")) == "houses");
	CHECK(result.failed.empty());
	CHECK(warnings.empty());
}

TEST_CASE("test_moveFilesAside_missingFile_leavesItUnmoved") {
	TempDirectory directory;
	writeFile(directory.path("map.otbm"), "map");
	std::vector<SaveFile> files { directory.saveFile("map.otbm"), directory.saveFile("map-npc.xml") };
	MapSaveResult result;
	std::vector<std::string> warnings;

	REQUIRE(moveFilesAside(files, directory.backups(false), result, warnings));

	CHECK(files[0].existed);
	CHECK_FALSE(files[1].existed);
	CHECK_FALSE(files[1].movedAside);
	CHECK_FALSE(exists(directory.path("map-npc.xml~")));
}

TEST_CASE("test_moveFilesAside_laterFileFails_restoresEarlierBackups") {
	TempDirectory directory;
	writeFile(directory.path("map.otbm"), "map");
	writeFile(directory.path("map-house.xml"), "houses");
	// A non-empty directory in the way of the house file's ~ copy cannot be deleted.
	fs::create_directories(utf8Path(directory.path("map-house.xml~")));
	writeFile(directory.path("map-house.xml~/blocker"), "");
	std::vector<SaveFile> files { directory.saveFile("map.otbm"), directory.saveFile("map-house.xml") };
	MapSaveResult result;
	std::vector<std::string> warnings;

	REQUIRE_FALSE(moveFilesAside(files, directory.backups(false), result, warnings));

	CHECK(readFile(directory.path("map.otbm")) == "map");
	CHECK_FALSE(exists(directory.path("map.otbm~")));
	CHECK(readFile(directory.path("map-house.xml")) == "houses");
	CHECK(result.restored == std::vector<std::string> { "map.otbm" });
	REQUIRE(result.failed.size() == 1);
	CHECK(result.failed[0].file == "map-house.xml");
	CHECK(result.error.starts_with("map-house.xml: could not delete the old"));
}

TEST_CASE("test_moveFilesAside_earlierBackupWithoutKeptBackups_deletesItWithWarning") {
	TempDirectory directory;
	writeFile(directory.path("map.otbm"), "current");
	writeFile(directory.path("map.otbm~"), "left by an earlier save");
	std::vector<SaveFile> files { directory.saveFile("map.otbm") };
	MapSaveResult result;
	std::vector<std::string> warnings;

	REQUIRE(moveFilesAside(files, directory.backups(false), result, warnings));

	CHECK(readFile(directory.path("map.otbm~")) == "current");
	CHECK_FALSE(exists(directory.path("backups")));
	CHECK(warnings.size() == 1);
}

TEST_CASE("test_moveFilesAside_earlierBackupWithKeptBackups_movesItIntoBackups") {
	TempDirectory directory;
	writeFile(directory.path("map.otbm"), "current");
	writeFile(directory.path("map.otbm~"), "left by an earlier save");
	std::vector<SaveFile> files { directory.saveFile("map.otbm") };
	MapSaveResult result;
	std::vector<std::string> warnings;

	REQUIRE(moveFilesAside(files, directory.backups(true), result, warnings));

	CHECK(readFile(directory.path("map.otbm~")) == "current");
	CHECK(readFile(directory.path("backups/map." + timestamp + ".otbm")) == "left by an earlier save");
	CHECK(warnings.empty());
}

TEST_CASE("test_rollBackSave_fileTheSaveCreated_removesIt") {
	TempDirectory directory;
	std::vector<SaveFile> files { directory.saveFile("map-zones.xml") };
	MapSaveResult result;
	std::vector<std::string> warnings;
	REQUIRE(moveFilesAside(files, directory.backups(false), result, warnings));
	writeFile(directory.path("map-zones.xml"), "half written");

	rollBackSave(files, result);

	CHECK_FALSE(exists(directory.path("map-zones.xml")));
	CHECK(result.removed == std::vector<std::string> { "map-zones.xml" });
}

TEST_CASE("test_rollBackSave_movedFile_replacesTheWrittenFileWithItsBackup") {
	TempDirectory directory;
	writeFile(directory.path("map.otbm"), "before");
	std::vector<SaveFile> files { directory.saveFile("map.otbm") };
	MapSaveResult result;
	std::vector<std::string> warnings;
	REQUIRE(moveFilesAside(files, directory.backups(false), result, warnings));
	writeFile(directory.path("map.otbm"), "half written");

	rollBackSave(files, result);

	CHECK(readFile(directory.path("map.otbm")) == "before");
	CHECK_FALSE(exists(directory.path("map.otbm~")));
	CHECK(result.restored == std::vector<std::string> { "map.otbm" });
}

TEST_CASE("test_moveIntoBackups_missingDirectory_createsItAndMovesTheBackup") {
	TempDirectory directory;
	writeFile(directory.path("map.otbm~"), "previous");

	CHECK(moveIntoBackups(directory.saveFile("map.otbm"), directory.backups(true)).empty());

	CHECK(readFile(directory.path("backups/map." + timestamp + ".otbm")) == "previous");
	CHECK_FALSE(exists(directory.path("map.otbm~")));
}

TEST_CASE("test_moveIntoBackups_datedNameTaken_appendsACounter") {
	TempDirectory directory;
	fs::create_directories(utf8Path(directory.path("backups")));
	writeFile(directory.path("backups/map." + timestamp + ".otbm"), "same second");
	writeFile(directory.path("backups/map." + timestamp + "-1.otbm"), "same second again");
	writeFile(directory.path("map.otbm~"), "previous");

	CHECK(moveIntoBackups(directory.saveFile("map.otbm"), directory.backups(true)).empty());

	CHECK(readFile(directory.path("backups/map." + timestamp + ".otbm")) == "same second");
	CHECK(readFile(directory.path("backups/map." + timestamp + "-1.otbm")) == "same second again");
	CHECK(readFile(directory.path("backups/map." + timestamp + "-2.otbm")) == "previous");
	CHECK_FALSE(exists(directory.path("map.otbm~")));
}

TEST_CASE("test_moveIntoBackups_nonAsciiPath_movesTheBackup") {
	TempDirectory directory;
	writeFile(directory.path("map\xC3\xA4.otbm~"), "previous");

	CHECK(moveIntoBackups(directory.saveFile("map\xC3\xA4.otbm"), directory.backups(true)).empty());

	CHECK(readFile(directory.path("backups/map\xC3\xA4." + timestamp + ".otbm")) == "previous");
}

TEST_CASE("test_retireSaveBackups_backupsKept_movesEachBackupIntoBackups") {
	TempDirectory directory;
	writeFile(directory.path("map.otbm"), "before");
	std::vector<SaveFile> files { directory.saveFile("map.otbm") };
	MapSaveResult result;
	std::vector<std::string> warnings;
	REQUIRE(moveFilesAside(files, directory.backups(true), result, warnings));

	CHECK(retireSaveBackups(files, directory.backups(true)).empty());

	CHECK(readFile(directory.path("backups/map." + timestamp + ".otbm")) == "before");
	CHECK_FALSE(exists(directory.path("map.otbm~")));
}

TEST_CASE("test_retireSaveBackups_backupsNotKept_deletesEachBackup") {
	TempDirectory directory;
	writeFile(directory.path("map.otbm"), "before");
	std::vector<SaveFile> files { directory.saveFile("map.otbm") };
	MapSaveResult result;
	std::vector<std::string> warnings;
	REQUIRE(moveFilesAside(files, directory.backups(false), result, warnings));

	CHECK(retireSaveBackups(files, directory.backups(false)).empty());

	CHECK_FALSE(exists(directory.path("map.otbm~")));
	CHECK_FALSE(exists(directory.path("backups")));
}
