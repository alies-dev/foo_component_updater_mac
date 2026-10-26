#pragma once

#include <string>

// コンポーネント(DLL名)と更新元の対応付け。Info.plist、Remote Registry、
// 同梱リスト、公式カタログのいずれから得たものもこの形で扱う。

struct RepositoryMappingEntry {
    std::string dllName;  // 拡張子(.dll)の有無は問わない。比較時に正規化する。
    std::string source;   // "github" / "gitlab" / "codeberg" / "marc2k3" / "sourceforge" / "hyv"。
    std::string owner;    // owner/repoモデル(github/gitlab/codeberg)用。
                           // marc2k3では未使用(空文字)。
    std::string repo;     // owner/repoモデル(github/gitlab/codeberg)用。
                           // marc2k3では未使用(空文字)。
    std::string url;      // urlモデル(marc2k3)用。コンポーネント個別ページのURLを
                           // そのまま保持する。github/gitlab/codebergでは未使用(空文字)。
};
