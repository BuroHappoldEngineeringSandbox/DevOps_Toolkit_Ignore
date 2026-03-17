This PR was opened automatically by the [sync-editorconfig](../actions/workflows/sync-editorconfig.yml) workflow in DevOps_Toolkit.

**What changed:** The canonical `.editorconfig` in `DevOps_Toolkit/config/.editorconfig` was updated.

**What this PR does:** Copies the updated file to the root of this repo so that IDE tooling (Roslyn, `dotnet format`) picks up the latest BHoM coding rules.

**To review the rules:** See [DevOps_Toolkit/config/.editorconfig](../../DevOps_Toolkit/blob/main/config/.editorconfig).

---
_Merge this PR to keep IDE feedback in sync with CI enforcement._
