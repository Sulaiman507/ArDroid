package com.ardroid.app.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.ardroid.app.ui.theme.ArDroidTokens

@Composable
fun ArDroidPrimaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.fillMaxWidth().height(44.dp),
        shape = RoundedCornerShape(ArDroidTokens.Radius.Button),
        colors = ButtonDefaults.buttonColors(
            // colorScheme.primary/onPrimary, not the fixed Accent literal, so the
            // primary button re-tints when the user enables dynamic color (the
            // fixed theme maps primary = Accent, so the default look is identical).
            containerColor = MaterialTheme.colorScheme.primary,
            contentColor   = MaterialTheme.colorScheme.onPrimary,
        ),
    ) {
        Text(text, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Medium)
    }
}

@Composable
fun ArDroidGhostButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.fillMaxWidth().height(44.dp),
        shape = RoundedCornerShape(ArDroidTokens.Radius.Button),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        colors = ButtonDefaults.outlinedButtonColors(
            contentColor = MaterialTheme.colorScheme.onSurface,
        ),
    ) {
        Text(text, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Medium)
    }
}

@Composable
fun ArDroidDestructiveButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.fillMaxWidth().height(44.dp),
        shape = RoundedCornerShape(ArDroidTokens.Radius.Button),
        border = BorderStroke(1.dp, ArDroidTokens.Red.copy(alpha = 0.5f)),
        colors = ButtonDefaults.outlinedButtonColors(
            contentColor = ArDroidTokens.Red,
        ),
    ) {
        Text(text, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Medium)
    }
}
