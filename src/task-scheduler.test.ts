import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { _initTestDatabase, createTask, getTaskById } from './db.js';
import {
  _resetSchedulerLoopForTests,
  startSchedulerLoop,
} from './task-scheduler.js';

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
});
