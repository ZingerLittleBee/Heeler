package dev.bybee.heeler.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val DarkColors = darkColorScheme(
    primary = Color(0xFF8BD5CA),
    onPrimary = Color(0xFF003732),
    primaryContainer = Color(0xFF005047),
    onPrimaryContainer = Color(0xFFA8F3E6),
    secondary = Color(0xFFB4CCC6),
    onSecondary = Color(0xFF203530),
    secondaryContainer = Color(0xFF374B46),
    onSecondaryContainer = Color(0xFFD0E8E1),
    tertiary = Color(0xFFB9C7F8),
    onTertiary = Color(0xFF23305D),
    tertiaryContainer = Color(0xFF3B4777),
    onTertiaryContainer = Color(0xFFDAE2FF),
    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),
    background = Color(0xFF101414),
    onBackground = Color(0xFFE0E4E1),
    surface = Color(0xFF101414),
    onSurface = Color(0xFFE0E4E1),
    surfaceVariant = Color(0xFF3F4946),
    onSurfaceVariant = Color(0xFFBEC9C4),
    outline = Color(0xFF89938F),
)

private val LightColors = lightColorScheme(
    primary = Color(0xFF006B60),
    onPrimary = Color.White,
    primaryContainer = Color(0xFF8FF8E8),
    onPrimaryContainer = Color(0xFF00201C),
    secondary = Color(0xFF4D635D),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFCFE9E1),
    onSecondaryContainer = Color(0xFF09201B),
    tertiary = Color(0xFF535F91),
    onTertiary = Color.White,
    tertiaryContainer = Color(0xFFDBE1FF),
    onTertiaryContainer = Color(0xFF101A4A),
    error = Color(0xFFBA1A1A),
    onError = Color.White,
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF410002),
    background = Color(0xFFF8FAF7),
    onBackground = Color(0xFF191C1B),
    surface = Color(0xFFF8FAF7),
    onSurface = Color(0xFF191C1B),
    surfaceVariant = Color(0xFFDBE5E0),
    onSurfaceVariant = Color(0xFF3F4946),
    outline = Color(0xFF6F7975),
)

/** Material 3 app theme. The console intentionally defaults dark for terminal work. */
@Composable
fun HeelerTheme(
    darkTheme: Boolean = true,
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        content = content,
    )
}
