mkdir -p audits/audit7/changes

# Сохранить основные файлы
git diff d7db0db..2d32914 > audits/audit7/changes/full_diff.patch
git diff d7db0db..2d32914 --stat > audits/audit7/changes/changes_statistics.txt
git diff d7db0db..2d32914 --name-status > audits/audit7/changes/changed_files.txt
git log d7db0db..2d32914 --oneline > audits/audit7/changes/commits_list.txt

# Автоматически сохранить diff для каждого измененного файла
git diff d7db0db..2d32914 --name-only | while read file; do
    filename=$(basename "$file")
    git diff d7db0db..2d32914 -- "$file" > "audits/audit7/changes/${filename}.diff"
done
