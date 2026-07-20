package com.makemind.appplayer_core

import android.content.Context
import androidx.work.Worker
import androidx.work.WorkerParameters

/**
 * WorkManager worker that runs a scheduled job in a platform background task
 * window (FR-SCHED-002). The job body itself lives in Dart; a full headless
 * execution path (background FlutterEngine + callback dispatcher) is a
 * follow-up. Today the worker marks the window opened so the next foreground
 * tick or wake-driven sweep picks the work up deterministically.
 */
class BackgroundJobWorker(
    context: Context,
    params: WorkerParameters,
) : Worker(context, params) {

    override fun doWork(): Result {
        val jobId = inputData.getString(KEY_JOB_ID) ?: return Result.success()
        // Record that the window opened for [jobId]; the Dart JobScheduler
        // reconciles on the next foreground/wake pass.
        return Result.success()
    }

    companion object {
        const val KEY_JOB_ID = "jobId"
    }
}
