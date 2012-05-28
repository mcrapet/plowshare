##
# Black-box test : upload, download and delete file
# Download will use captcha.trader (stored in plowshare.conf).
# Delete function is optional.
# Remark: Most hosters remove inactive files.
#
# File syntax:
# 1. module name
# 2. plowup options ("--" means no option)
# 3. plowdown options ("--" means no option)
# 4. plowdel options ("--" means no option)
##

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
cramit
--no-plowsharerc
--
--no-plowsharerc
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
depositfiles
--no-plowsharerc
--
--no-plowsharerc
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
freakshare
--no-plowsharerc
--
--no-plowsharerc
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
oron
--no-plowsharerc
--
--no-plowsharerc
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
turbobit
--no-plowsharerc
--
--no-plowsharerc
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
