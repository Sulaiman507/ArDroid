/*
 * ArDroid - Rootless Podman for Android
 * Copyright (C) 2024-2026 ArDroid contributors
 */
package com.ardroid.app.engine

/**
 * User-facing backend choice. Persisted in DataStore as the enum name string.
 * AUTO = detect AVF at startup, fall back to QEMU. 99% case.
 */
enum class EngineSelection { AUTO, AVF, QEMU }
