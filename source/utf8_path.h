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

#ifndef RME_UTF8_PATH_H_
#define RME_UTF8_PATH_H_

#include <filesystem>
#include <string>
#include <string_view>

// MSVC decodes a path built from a narrow string with the ANSI code page, so a
// UTF-8 path from wxString::mb_str(wxConvUTF8) is marked as UTF-8 explicitly.
inline std::filesystem::path utf8Path(std::string_view utf8) {
	return std::filesystem::path(std::u8string_view(reinterpret_cast<const char8_t*>(utf8.data()), utf8.size()));
}

inline std::string utf8String(const std::filesystem::path &path) {
	const std::u8string utf8 = path.u8string();
	return std::string(reinterpret_cast<const char*>(utf8.data()), utf8.size());
}

#endif
