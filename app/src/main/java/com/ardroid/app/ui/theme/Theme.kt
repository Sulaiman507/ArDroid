/*
 * ArDroid Compose theme.
 *
 * Default identity: fixed dark/light palette derived from ArDroidTokens, with
 * a lime-green accent (#4ade80). Material You wallpaper-derived dynamic color
 * is OFF by default — users opt in via Settings → Appearance → Dynamic color,
 * which flows in via the dynamicColor parameter.
 */
package com.ardroid.app.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext

private val ArDroidDark = darkColorScheme(
    primary             = ArDroidAccent,
    onPrimary           = ArDroidAccentInk,
    primaryContainer    = ArDroidDarkSurface2,
    onPrimaryContainer  = ArDroidDarkText,

    secondary           = ArDroidAccent,
    onSecondary         = ArDroidAccentInk,
    secondaryContainer  = ArDroidDarkSurface2,
    onSecondaryContainer= ArDroidDarkText,

    tertiary            = ArDroidAmber,
    onTertiary          = ArDroidAccentInk,

    background          = ArDroidDarkBg,
    onBackground        = ArDroidDarkText,
    surface             = ArDroidDarkSurface,
    onSurface           = ArDroidDarkText,
    surfaceVariant      = ArDroidDarkSurface2,
    onSurfaceVariant    = ArDroidDarkTextMute,
    surfaceContainerHighest = ArDroidDarkSurface2,

    outline             = ArDroidDarkBorder,
    outlineVariant      = ArDroidDarkBorder,

    error               = ArDroidRed,
    onError             = ArDroidDarkText,
    errorContainer      = ArDroidDarkSurface2,
    onErrorContainer    = ArDroidRed,
)

private val ArDroidLight = lightColorScheme(
    primary             = ArDroidAccent,
    onPrimary           = ArDroidAccentInk,
    primaryContainer    = ArDroidLightSurface2,
    onPrimaryContainer  = ArDroidLightText,

    secondary           = ArDroidAccent,
    onSecondary         = ArDroidAccentInk,
    secondaryContainer  = ArDroidLightSurface2,
    onSecondaryContainer= ArDroidLightText,

    tertiary            = ArDroidAmber,
    onTertiary          = ArDroidLightText,

    background          = ArDroidLightBg,
    onBackground        = ArDroidLightText,
    surface             = ArDroidLightSurface,
    onSurface           = ArDroidLightText,
    surfaceVariant      = ArDroidLightSurface2,
    onSurfaceVariant    = ArDroidLightTextMute,
    surfaceContainerHighest = ArDroidLightSurface2,

    outline             = ArDroidLightBorder,
    outlineVariant      = ArDroidLightBorder,

    error               = ArDroidRed,
    onError             = ArDroidLightText,
    errorContainer      = ArDroidLightSurface2,
    onErrorContainer    = ArDroidRed,
)

@Composable
fun ArDroidTheme(
    darkTheme: Boolean? = null,
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit,
) {
    val effectiveDark = darkTheme ?: isSystemInDarkTheme()
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val ctx = LocalContext.current
            if (effectiveDark) dynamicDarkColorScheme(ctx) else dynamicLightColorScheme(ctx)
        }
        effectiveDark -> ArDroidDark
        else          -> ArDroidLight
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography  = buildArDroidTypography(),
        content     = content,
    )
}
