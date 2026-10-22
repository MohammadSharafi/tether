package dev.tether.app

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val Coral = Color(0xFFE88866)
val Bg = Color(0xFF0E0E11)
val Card = Color(0xFF1B1B20)
val CardHigh = Color(0xFF26262C)
val Muted = Color(0xFF9A9AA6)
val Good = Color(0xFF5AD278)
val Warn = Color(0xFFF2A33A)

@Composable
fun TetherTheme(content: @Composable () -> Unit) = MaterialTheme(
    colorScheme = darkColorScheme(
        primary = Coral, onPrimary = Color(0xFF1B1B20), background = Bg, surface = Bg, onSurface = Color(0xFFF2F2F5),
        surfaceVariant = Card, onSurfaceVariant = Muted, surfaceContainer = Card, surfaceContainerHigh = CardHigh,
        error = Color(0xFFFF6B6B),
    ),
    content = content,
)
