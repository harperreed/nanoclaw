import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  _initTestDatabase,
  createTask,
  getTaskById,
  updateTask,
  updateTaskAfterRun,
} from './db.js';
import {
  _resetSchedulerLoopForTests,
  computeNextRun,
  startSchedulerLoop,
} from './task-scheduler.js';

// Use UTC timezone for predictable cron calculations in tests
vi.mock('./config.js', async () => {
  const actual =
    await vi.importActual<typeof import('./config.js')>('./config.js');
  return { ...actual, TIMEZONE: 'UTC' };
});

describe('task scheduler', () => {
  beforeEach(() => {
    _initTestDatabase();
    _resetSchedulerLoopForTests();
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('advances next_run before executing task to prevent duplicate runs', async () => {
    const now = Date.now();
    createTask({
      id: 'task-cron-dedup',
      group_folder: 'main',
      chat_jid: 'test@s.whatsapp.net',
      prompt: 'test',
      schedule_type: 'cron',
      schedule_value: '0 9 * * *',
      context_mode: 'isolated',
      next_run: new Date(now - 60_000).toISOString(),
      status: 'active',
      created_at: new Date(now - 120_000).toISOString(),
    });

    let nextRunAtEnqueueTime: string | null | undefined;
    const enqueueTask = vi.fn(
      (_groupJid: string, _taskId: string, _fn: () => Promise<void>) => {
        // Capture next_run at the moment enqueueTask is called (before task runs)
        const task = getTaskById('task-cron-dedup');
        nextRunAtEnqueueTime = task?.next_run;
      },
    );

    startSchedulerLoop({
      registeredGroups: () => ({}),
      getSessions: () => ({}),
      queue: { enqueueTask } as any,
      onProcess: () => {},
      sendMessage: async () => {},
    });

    await vi.advanceTimersByTimeAsync(10);

    expect(enqueueTask).toHaveBeenCalledOnce();
    // next_run should already be advanced to the future before the task callback runs
    expect(nextRunAtEnqueueTime).toBeDefined();
    expect(new Date(nextRunAtEnqueueTime!).getTime()).toBeGreaterThan(now);
  });

  it('clears next_run for once tasks before executing to prevent duplicate runs', async () => {
    const now = Date.now();
    createTask({
      id: 'task-once-dedup',
      group_folder: 'main',
      chat_jid: 'test@s.whatsapp.net',
      prompt: 'test',
      schedule_type: 'once',
      schedule_value: new Date(now - 60_000).toISOString(),
      context_mode: 'isolated',
      next_run: new Date(now - 60_000).toISOString(),
      status: 'active',
      created_at: new Date(now - 120_000).toISOString(),
    });

    let nextRunAtEnqueueTime: string | null | undefined;
    const enqueueTask = vi.fn(
      (_groupJid: string, _taskId: string, _fn: () => Promise<void>) => {
        const task = getTaskById('task-once-dedup');
        nextRunAtEnqueueTime = task?.next_run;
      },
    );

    startSchedulerLoop({
      registeredGroups: () => ({}),
      getSessions: () => ({}),
      queue: { enqueueTask } as any,
      onProcess: () => {},
      sendMessage: async () => {},
    });

    await vi.advanceTimersByTimeAsync(10);

    expect(enqueueTask).toHaveBeenCalledOnce();
    // next_run should be null for once tasks — prevents getDueTasks from returning it again
    expect(nextRunAtEnqueueTime).toBeNull();
  });

  it('pauses due tasks with invalid group folders to prevent retry churn', async () => {
    createTask({
      id: 'task-invalid-folder',
      group_folder: '../../outside',
      chat_jid: 'bad@g.us',
      prompt: 'run',
      schedule_type: 'once',
      schedule_value: '2026-02-22T00:00:00.000Z',
      context_mode: 'isolated',
      next_run: new Date(Date.now() - 60_000).toISOString(),
      status: 'active',
      created_at: '2026-02-22T00:00:00.000Z',
    });

    const enqueueTask = vi.fn(
      (_groupJid: string, _taskId: string, fn: () => Promise<void>) => {
        void fn();
      },
    );

    startSchedulerLoop({
      registeredGroups: () => ({}),
      getSessions: () => ({}),
      queue: { enqueueTask } as any,
      onProcess: () => {},
      sendMessage: async () => {},
    });

    await vi.advanceTimersByTimeAsync(10);

    const task = getTaskById('task-invalid-folder');
    expect(task?.status).toBe('paused');
  });

  it('computeNextRun anchors interval tasks to scheduled time to prevent drift', () => {
    const scheduledTime = new Date(Date.now() - 2000).toISOString(); // 2s ago
    const task = {
      id: 'drift-test',
      group_folder: 'test',
      chat_jid: 'test@g.us',
      prompt: 'test',
      schedule_type: 'interval' as const,
      schedule_value: '60000', // 1 minute
      context_mode: 'isolated' as const,
      next_run: scheduledTime,
      last_run: null,
      last_result: null,
      status: 'active' as const,
      created_at: '2026-01-01T00:00:00.000Z',
    };

    const nextRun = computeNextRun(task);
    expect(nextRun).not.toBeNull();

    // Should be anchored to scheduledTime + 60s, NOT Date.now() + 60s
    const expected = new Date(scheduledTime).getTime() + 60000;
    expect(new Date(nextRun!).getTime()).toBe(expected);
  });

  it('recovers missed cron tasks on startup by resetting next_run', async () => {
    // Freeze time to a specific point: 9:15 AM on a known date
    vi.setSystemTime(new Date('2026-03-08T09:15:00.000Z'));
    const now = Date.now();

    // Simulate: daily 8am task. Service was down at 8am so next_run was
    // already advanced to tomorrow 8am. last_run is from yesterday.
    createTask({
      id: 'task-missed',
      group_folder: 'news',
      chat_jid: 'test@s.whatsapp.net',
      prompt: 'missed digest',
      schedule_type: 'cron',
      schedule_value: '0 8 * * *', // daily at 8am UTC
      context_mode: 'isolated',
      // next_run skipped to tomorrow 8am
      next_run: '2026-03-09T08:00:00.000Z',
      status: 'active',
      created_at: '2026-03-01T00:00:00.000Z',
    });
    // last_run needs to be from yesterday -- but updateTaskAfterRun sets it to
    // Date.now(). So we temporarily shift time back to simulate the prior run.
    vi.setSystemTime(new Date('2026-03-07T08:05:00.000Z'));
    updateTaskAfterRun('task-missed', '2026-03-09T08:00:00.000Z', 'ok');
    vi.setSystemTime(new Date('2026-03-08T09:15:00.000Z'));

    // Task whose next_run is in the future but ran on schedule
    // (last_run covers the previous window) -- should NOT be recovered
    createTask({
      id: 'task-ok',
      group_folder: 'weather',
      chat_jid: 'test@s.whatsapp.net',
      prompt: 'weather check',
      schedule_type: 'cron',
      schedule_value: '0 18 * * *', // daily at 6pm UTC
      context_mode: 'isolated',
      // next_run is today at 6pm (still in the future, on schedule)
      next_run: '2026-03-08T18:00:00.000Z',
      status: 'active',
      created_at: '2026-03-01T00:00:00.000Z',
    });
    // Ran yesterday at 6pm -- correctly on schedule
    vi.setSystemTime(new Date('2026-03-07T18:05:00.000Z'));
    updateTaskAfterRun('task-ok', '2026-03-08T18:00:00.000Z', 'ok');
    vi.setSystemTime(new Date('2026-03-08T09:15:00.000Z'));

    const enqueueTask = vi.fn();

    startSchedulerLoop({
      registeredGroups: () => ({}),
      getSessions: () => ({}),
      queue: { enqueueTask } as any,
      onProcess: () => {},
      sendMessage: async () => {},
    });

    await vi.advanceTimersByTimeAsync(10);

    // Check which tasks were enqueued
    const enqueuedIds = enqueueTask.mock.calls.map((c: unknown[]) => c[1]);

    // The missed task should have been enqueued
    expect(enqueuedIds).toContain('task-missed');

    // The ok task should NOT have been enqueued (it ran on schedule)
    expect(enqueuedIds).not.toContain('task-ok');
  });

  it('computeNextRun returns null for once-tasks', () => {
    const task = {
      id: 'once-test',
      group_folder: 'test',
      chat_jid: 'test@g.us',
      prompt: 'test',
      schedule_type: 'once' as const,
      schedule_value: '2026-01-01T00:00:00.000Z',
      context_mode: 'isolated' as const,
      next_run: new Date(Date.now() - 1000).toISOString(),
      last_run: null,
      last_result: null,
      status: 'active' as const,
      created_at: '2026-01-01T00:00:00.000Z',
    };

    expect(computeNextRun(task)).toBeNull();
  });

  it('computeNextRun skips missed intervals without infinite loop', () => {
    // Task was due 10 intervals ago (missed)
    const ms = 60000;
    const missedBy = ms * 10;
    const scheduledTime = new Date(Date.now() - missedBy).toISOString();

    const task = {
      id: 'skip-test',
      group_folder: 'test',
      chat_jid: 'test@g.us',
      prompt: 'test',
      schedule_type: 'interval' as const,
      schedule_value: String(ms),
      context_mode: 'isolated' as const,
      next_run: scheduledTime,
      last_run: null,
      last_result: null,
      status: 'active' as const,
      created_at: '2026-01-01T00:00:00.000Z',
    };

    const nextRun = computeNextRun(task);
    expect(nextRun).not.toBeNull();
    // Must be in the future
    expect(new Date(nextRun!).getTime()).toBeGreaterThan(Date.now());
    // Must be aligned to the original schedule grid
    const offset =
      (new Date(nextRun!).getTime() - new Date(scheduledTime).getTime()) % ms;
    expect(offset).toBe(0);
  });
});
