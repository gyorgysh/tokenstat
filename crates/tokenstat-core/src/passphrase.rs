// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! The rule a vault master password has to meet, in one place.
//!
//! Every client asks the same question and has to give the same answer, and a
//! rule written out per client is a rule that disagrees with itself the first
//! time one of them is edited. The host checks it before wrapping a key, so a
//! client that forgets to check cannot create a vault behind a weak password.

/// Why a password was refused. Carries its own sentence, because the client
/// showing it should not be composing security copy of its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PasswordProblem {
    TooShort,
    NeedsUppercase,
    NeedsNumber,
    NeedsSpecial,
}

impl PasswordProblem {
    pub fn message(self) -> &'static str {
        match self {
            Self::TooShort => "Use at least 12 characters.",
            Self::NeedsUppercase => "Add an uppercase letter.",
            Self::NeedsNumber => "Add a number.",
            Self::NeedsSpecial => "Add a special character.",
        }
    }
}

/// The shortest password the vault will accept.
///
/// Twelve, not eight. This one key opens every saved server and every private
/// key on the account, the ciphertext is on a server, and an offline guess is
/// therefore always available to somebody who takes a copy. Argon2id makes each
/// guess expensive, and the length is what makes there be too many of them.
pub const MIN_LENGTH: usize = 12;

/// Everything wrong with this password, in the order a person would fix it.
/// Empty means it is acceptable.
pub fn password_problems(password: &str) -> Vec<PasswordProblem> {
    let mut out = Vec::new();
    // Counted in characters rather than bytes, so a password written in a
    // non-Latin script is measured the way its author would measure it.
    if password.chars().count() < MIN_LENGTH {
        out.push(PasswordProblem::TooShort);
    }
    if !password.chars().any(char::is_uppercase) {
        out.push(PasswordProblem::NeedsUppercase);
    }
    if !password.chars().any(|c| c.is_ascii_digit()) {
        out.push(PasswordProblem::NeedsNumber);
    }
    // Anything that is not a letter, a number or a space. Defining it by what
    // it is not keeps punctuation from other keyboards in.
    if !password
        .chars()
        .any(|c| !c.is_alphanumeric() && !c.is_whitespace())
    {
        out.push(PasswordProblem::NeedsSpecial);
    }
    out
}

/// One sentence naming everything still missing, or `None` when it passes.
pub fn password_error(password: &str) -> Option<String> {
    let problems = password_problems(password);
    if problems.is_empty() {
        return None;
    }
    Some(
        problems
            .iter()
            .map(|p| p.message())
            .collect::<Vec<_>>()
            .join(" "),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_password_meeting_every_rule_is_accepted() {
        assert!(password_error("Correct-Horse9").is_none());
        assert!(password_error("aB3!aB3!aB3!").is_none());
    }

    #[test]
    fn each_missing_rule_is_named() {
        assert_eq!(password_problems("Ab3!"), vec![PasswordProblem::TooShort]);
        assert_eq!(
            password_problems("lowercase12!"),
            vec![PasswordProblem::NeedsUppercase]
        );
        assert_eq!(
            password_problems("NoDigitsHere!"),
            vec![PasswordProblem::NeedsNumber]
        );
        assert_eq!(
            password_problems("NoSpecials123"),
            vec![PasswordProblem::NeedsSpecial]
        );
    }

    #[test]
    fn everything_wrong_is_reported_at_once() {
        // Not one rule at a time. Being told to add a number, then an
        // uppercase, then a symbol is three rejections for one password.
        assert_eq!(password_problems("short").len(), 4);
        let message = password_error("short").unwrap();
        assert!(message.contains("12 characters"));
        assert!(message.contains("special"));
    }

    #[test]
    fn length_is_counted_in_characters_not_bytes() {
        // Twelve characters, more than twelve bytes. Byte length would have
        // accepted this at nine characters.
        assert!(
            password_problems("Ünnepélyes1!")
                .iter()
                .all(|p| *p != PasswordProblem::TooShort)
        );
    }

    #[test]
    fn a_space_alone_is_not_a_special_character() {
        assert!(password_problems("Just Words 12").contains(&PasswordProblem::NeedsSpecial));
    }
}
