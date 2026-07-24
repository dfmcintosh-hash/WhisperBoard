# Ruminate Board Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add validated multi-board chat to WhisperBoard while leaving the Phase-1 Ruminate seat lane unchanged.

**Architecture:** New board-only models, persistence, HTTP client, delivery coordinator, and selected-thread poll controller live beside the existing seat implementation. `ChatViewModel` routes the seat to existing `ChatStore`/`DeliveryActor` and board selections to these new components; remote journal rows never enter the outgoing queue.

**Tech Stack:** Swift 5.9, SwiftUI, Foundation concurrency, XCTest, URLProtocol fixtures.

## Global Constraints

- Branch `feat/ruminate-board-chat` from `main`.
- `project.yml` remains authoritative; its existing source globs include new files.
- Preserve `Ruminate/turns.json`, `LocalTurn`, `HistoryTurn`, `ChatStore.merge()`, and Phase-1 polling unchanged.
- Board delivery terminates at `delivered` and makes zero turn-status calls.
- Exact chip: `Delivered — ORCH responds when it surfaces`.
- Never trigger `ios.yml`; `ci-build.yml` is the compile/test gate.
- Push no more than two numbered tasks in one batch.

---

### Task 1: Board identity and bridge DTO/client

**Files:** Create `WhisperBoard/Sources/Ruminate/BoardID.swift`, `BoardDTO.swift`, `BoardClient.swift`; test `WhisperBoardTests/BoardIDTests.swift`, `BoardClientTests.swift`.

**Interfaces:** `BoardID.init(validating:)`, collision-free `filename`, `BoardClientProtocol.fetchBoards/postAsk/history` using exact REV 2 envelopes and one encoded board path component.

- [ ] Write validation, filename-collision, DTO decode, bearer, request-body, query, and URL-path tests.
- [ ] Run CI test gate and confirm RED because board types do not exist.
- [ ] Implement minimal identity, DTO, and client code.
- [ ] Run CI and confirm Task 1 tests plus Phase-1 tests pass.

### Task 2: Separate board persistence models

**Files:** Create `WhisperBoard/Sources/Ruminate/BoardStore.swift`; test `WhisperBoardTests/BoardStoreTests.swift`.

**Interfaces:** `OutgoingBoardAsk`, `BoardAskState`, durable `BoardStore`; rows dedupe by `(claimID, ord)`; cursors keyed by `BoardHistoryMode`; file remains under `Ruminate/boards/<BoardID.filename>.json`.

- [ ] Write failing isolation, persistence, dedupe, and cursor-independence tests.
- [ ] Implement atomic Codable persistence without changing seat models.
- [ ] Run focused and full CI.

### Task 3: Terminal board delivery strategy

**Files:** Create `WhisperBoard/Sources/Ruminate/BoardDelivery.swift`; test `WhisperBoardTests/BoardDeliveryTests.swift`.

**Interfaces:** `BoardDeliveryActor.flush()` transitions queued to sending to delivered; transport requeues; auth/failure/ambiguity are explicit; no status API exists in `BoardClientProtocol`.

- [ ] Write failing terminal-delivery, exact-chip, FIFO, retry, and error tests.
- [ ] Implement minimal actor and exact display copy.
- [ ] Run focused and full CI.

### Task 4: Selection-independent delivery coordinator

**Files:** Modify `BoardDelivery.swift`; test `BoardDeliveryCoordinatorTests.swift`.

**Interfaces:** `BoardDeliveryCoordinator.register(store:)`, `discoverAndFlush()`, and `flushAll()` scan/decode all board store files and serially flush each board regardless of selection.

- [ ] Write failing A+B offline/reconnect test with only B selected.
- [ ] Implement registry plus directory discovery and serial flushing.
- [ ] Run focused and full CI.

### Task 5: Selected-thread polling and cursor lifecycle

**Files:** Create `WhisperBoard/Sources/Ruminate/BoardThreadController.swift`; test `WhisperBoardTests/BoardThreadControllerTests.swift`.

**Interfaces:** Main-actor controller uses generation guards, immediate fetch plus cadence, cancellation on stop/switch, conflict resets only the affected `(board, mode)` cursor.

- [ ] Write failing immediate-fetch, stop, switch-race, foreground, cursor-mode, and 409-reset tests.
- [ ] Implement cancellable polling with injected sleep.
- [ ] Run focused and full CI.

### Task 6: Board list and dual-mode UI

**Files:** Modify `WhisperBoard/Sources/Views/ChatView.swift`; create `WhisperBoard/Sources/Ruminate/BoardChatViewModel.swift`; test `WhisperBoardTests/BoardChatViewModelTests.swift`.

**Interfaces:** Board dropdown defaults/falls back to seat, persists valid selection, refreshes on appear/foreground/explicit action, retains stale cache on transport error, provides conversation/full projections, and excludes ledger row actions.

- [ ] Write failing selection fallback, stale-list, refresh, projection, and ledger-exclusion tests.
- [ ] Implement view model and SwiftUI dropdown/toggle/rows while retaining the seat view path.
- [ ] Run focused and full CI.

### Task 7: Full regression battery and evidence

**Files:** Expand board test files as needed; create workflow evidence outside the repo.

- [ ] Add interleaved mode/append, hostile BoardID, board-switch race, coordinator relaunch, exact chip, and Phase-1 preservation assertions.
- [ ] Run `ci-build.yml`, capture green URL and test count.
- [ ] Push final branch commits and write `findings/BUILD2_DATA_EVIDENCE.md`.
- [ ] Post required DONE message.
