@echo off
rem Chay trong thu muc goc cua repo (noi co thu muc .git).
rem Buoc 1: chuan hoa xuong dong theo .gitattributes. Buoc 2 (cuoi cung): dat quyen thuc thi 100755 trong Git.
rem Thu tu quan trong: chay renormalize sau se ghi de quyen.
git add --renormalize .
for /f %%i in ('git ls-files "bin/*.sh" "tests/*.sh" install.sh container/entrypoint.sh packaging/postinst packaging/postinst-agent packaging/prerm') do git update-index --chmod=+x %%i
echo.
echo Kiem tra: moi dong duoi day phai bat dau bang 100755
git ls-files --stage bin/cert-deploy.sh bin/pbx-agent.sh install.sh container/entrypoint.sh
echo.
echo Neu dung, chay tiep: git commit -m "Sua quyen thuc thi va xuong dong cho Linux" va git push
