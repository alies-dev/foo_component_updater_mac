#pragma once

#include <cstdint>

#include "../version.h"

// 自動確認の設定値(cfg_var)へのアクセスを、他のファイル(設定ダイアログ等)へ
// 公開するためのヘッダー。実体はautomatic_check.cppにある。

bool GetAutomaticCheckEnabled();
void SetAutomaticCheckEnabled(bool enabled);

// UNIXエポック秒。0 = 未実施。最後に行った確認(手動・メニュー・自動のいずれも)の時刻。
int64_t GetAutomaticCheckLastRun();

// メインスレッドで、確認が完了したときに呼ぶ(手動・メニュー・自動のすべて)。
void MarkCheckCompletedNow();

// 単位: 日数。1未満は指定しないこと(呼び出し側でバリデーションする想定)。
int GetAutomaticCheckIntervalDays();
void SetAutomaticCheckIntervalDays(int days);

// 自動確認で、何が見つかったときにポップアップを出すか。
enum class AutoCheckNotificationLevel {
    UpdatesOnly = 0,      // 既定: 更新が見つかったときだけ
    UpdatesAndErrors = 1, // 更新に加えて、通信失敗などのエラーがあったときも
    Always = 2,           // 何も無くても(Up to dateのみでも)必ず表示する
};

AutoCheckNotificationLevel GetAutomaticCheckNotificationLevel();
void SetAutomaticCheckNotificationLevel(AutoCheckNotificationLevel level);

// メインスレッドで呼ぶ。期限が来ていて、確認も結果ウィンドウも無ければ確認を始める。
// 始めたらtrueを返す。
bool EvaluateAutomaticCheck();

#ifdef FCU_DEBUG_HOOKS
void DebugSetAutomaticCheckLastRun(int64_t epoch);
#endif
