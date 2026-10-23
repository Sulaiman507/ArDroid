package com.ardroid.app.ui.components

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import com.ardroid.app.ui.theme.ArDroidTokens

/**
 * Tiny uppercase tracked label used as a section heading throughout the app.
 * Pairs naturally with ArDroidListRow groups.
 */
@Composable
fun ArDroidSectionLabel(
    text: String,
    modifier: Modifier = Modifier,
) {
    Text(
        text = text.uppercase(),
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        fontFamily = ArDroidTokens.ui(),
        fontWeight = FontWeight.Medium,
        modifier = modifier
            .padding(top = ArDroidTokens.Spacing.LG, bottom = ArDroidTokens.Spacing.XS),
    )
}
